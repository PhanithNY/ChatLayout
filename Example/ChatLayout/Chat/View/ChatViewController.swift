//
// ChatLayout
// ChatViewController.swift
// https://github.com/ekazaev/ChatLayout
//
// Created by Eugene Kazaev in 2020.
// Distributed under the MIT license.
//

import ChatLayout
import DifferenceKit
import Foundation
import InputBarAccessoryView
import UIKit

final class ChatViewController: UIViewController {

    private enum ReactionTypes {
        case delayedUpdate
        case delayedReload
    }

    private enum InterfaceActions {
        case changingKeyboardFrame
        case changingFrameSize
        case sendingMessage
        case scrollingToTop
        case scrollingToBottom
    }

    private enum ControllerActions {
        case loadingInitialMessages
        case loadingPreviousMessages
    }

    override var inputAccessoryView: UIView? {
        return inputBarView
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    private var currentInterfaceActions: SetActor<Set<InterfaceActions>, ReactionTypes> = SetActor()
    private var currentControllerActions: SetActor<Set<ControllerActions>, ReactionTypes> = SetActor()
    private let editNotifier: EditNotifier
    private var collectionView: UICollectionView!
    private var chatLayout = ChatLayout()
    private let inputBarView = InputBarAccessoryView()
    private let chatController: ChatController

    private let dataSource: ChatCollectionDataSource

    init(chatController: ChatController,
         dataSource: ChatCollectionDataSource,
         editNotifier: EditNotifier) {
        self.chatController = chatController
        self.dataSource = dataSource
        self.editNotifier = editNotifier
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable, message: "Use init(messageController:) instead")
    override convenience init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        fatalError()
    }

    @available(*, unavailable, message: "Use init(messageController:) instead")
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }

        inputBarView.delegate = self

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Show Keyboard", style: .plain, target: self, action: #selector(ChatViewController.showHideKeyboard))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Edit", style: .plain, target: self, action: #selector(ChatViewController.setEditNotEdit))

        chatLayout.settings.interItemSpacing = 8
        chatLayout.settings.interSectionSpacing = 8
        chatLayout.settings.additionalInsets = UIEdgeInsets(top: 8, left: 5, bottom: 8, right: 5)
        chatLayout.keepContentOffsetAtBottomOnBatchUpdates = true

        collectionView = UICollectionView(frame: view.frame, collectionViewLayout: chatLayout)
        view.addSubview(collectionView)
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = dataSource
        chatLayout.delegate = dataSource
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive

        /// https://openradar.appspot.com/40926834
        collectionView.isPrefetchingEnabled = false

        collectionView.contentInsetAdjustmentBehavior = .always
        if #available(iOS 13.0, *) {
            collectionView.automaticallyAdjustsScrollIndicatorInsets = true
        }

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.frame = view.bounds
        collectionView.topAnchor.constraint(equalTo: view.topAnchor, constant: 0).isActive = true
        collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0).isActive = true
        collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0).isActive = true
        collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0).isActive = true
        dataSource.prepare(with: collectionView)
        collectionView.backgroundColor = .clear

        currentControllerActions.options.insert(.loadingInitialMessages)
        chatController.loadInitialMessages { sections in
            self.currentControllerActions.options.remove(.loadingInitialMessages)
            self.processUpdates(with: sections, animated: true)
        }

        KeyboardListener.shared.add(delegate: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        collectionView.collectionViewLayout.invalidateLayout()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        currentInterfaceActions.options.insert(.changingFrameSize)
        let positionSnapshot = chatLayout.getContentOffsetSnapshot(from: .bottom)
        coordinator.animate(alongsideTransition: { _ in
            // Gives nicer transition behaviour
            self.collectionView.performBatchUpdates({})
        }, completion: { _ in
            if let positionSnapshot = positionSnapshot {
                self.chatLayout.restoreContentOffset(with: positionSnapshot)
            }
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.currentInterfaceActions.options.remove(.changingFrameSize)
        })
        super.viewWillTransition(to: size, with: coordinator)
    }

    @objc private func showHideKeyboard() {
        if inputBarView.inputTextView.isFirstResponder {
            navigationItem.leftBarButtonItem?.title = "Show Keyboard"
            inputBarView.inputTextView.resignFirstResponder()
        } else {
            navigationItem.leftBarButtonItem?.title = "Hide Keyboard"
            inputBarView.inputTextView.becomeFirstResponder()
        }
    }

    @objc private func setEditNotEdit() {
        isEditing = !isEditing
        editNotifier.setIsEditing(isEditing, duration: .animated(duration: 0.25))
        navigationItem.rightBarButtonItem?.title = isEditing ? "Done" : "Edit"
        chatLayout.invalidateLayout()
    }

}

extension ChatViewController: UIScrollViewDelegate {

    public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        // Blocking the call of loadPreviousMessages() as UIScrollView behaves the way that it will scroll to the top even if we keep adding
        // content there and keep changing the content offset until it actually reaches the top. So instead we wait until it reaches the top and initialte
        // the loading then.
        currentInterfaceActions.options.insert(.scrollingToTop)
        return true
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        guard !currentControllerActions.options.contains(.loadingInitialMessages),
            !currentControllerActions.options.contains(.loadingPreviousMessages) else {
            return
        }
        currentInterfaceActions.options.remove(.scrollingToTop)
        loadPreviousMessages()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !currentControllerActions.options.contains(.loadingInitialMessages),
            !currentControllerActions.options.contains(.loadingPreviousMessages),
            !currentInterfaceActions.options.contains(.scrollingToTop) else {
            return
        }

        if scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + scrollView.bounds.height {
            loadPreviousMessages()
        }
    }

    private func loadPreviousMessages() {
        // Blocking the potential multiple call of that function as during the content invalidation the contentOffset of the UICollectionView can change
        // in any way so it may trigger another call of that function and lead to unexpected behaviour/animation
        currentControllerActions.options.insert(.loadingPreviousMessages)
        chatController.loadPreviousMessages { [weak self] sections in
            guard let self = self else {
                return
            }
            let animated = !self.collectionView.isDragging && !self.collectionView.isDecelerating
            // Reloading the content without animation just because it looks better is the scrolling is in process.
            self.processUpdates(with: sections, animated: animated) {
                self.currentControllerActions.options.remove(.loadingPreviousMessages)
            }
        }
    }

    func scrollToBottom(completion: (() -> Void)? = nil) {
        // I ask content size from the layout because on IOs 12 collection view contains not updated one
        let contentOffsetAtBottom = CGPoint(x: collectionView.contentOffset.x, y: chatLayout.collectionViewContentSize.height - collectionView.frame.height + collectionView.adjustedContentInset.bottom)

        currentInterfaceActions.options.insert(.scrollingToTop)
        UIView.animate(withDuration: 0.25, animations: { [weak self] in
            self?.collectionView.setContentOffset(contentOffsetAtBottom, animated: true)
        }, completion: { [weak self] _ in
            self?.currentInterfaceActions.options.remove(.scrollingToTop)
            completion?()
        })
    }

}

extension ChatViewController: UICollectionViewDelegate {}

extension ChatViewController: ChatControllerDelegate {

    func update(with sections: [Section]) {
        processUpdates(with: sections, animated: true)
    }

    private func processUpdates(with sections: [Section], animated: Bool = true, completion: (() -> Void)? = nil) {
        guard isViewLoaded else {
            dataSource.sections = sections
            return
        }

        guard currentInterfaceActions.options.isEmpty else {
            let reaction = SetActor<Set<InterfaceActions>, ReactionTypes>.Reaction(type: .delayedUpdate,
                                                                                   action: .onEmpty,
                                                                                   executionType: .once,
                                                                                   actionBlock: { [weak self] in
                                                                                       guard let self = self else {
                                                                                           return
                                                                                       }
                                                                                       self.processUpdates(with: sections, animated: animated, completion: completion)
                })
            currentInterfaceActions.add(reaction: reaction)
            return
        }

        let changeSet = StagedChangeset(source: dataSource.sections, target: sections)

        func process() {
            self.dataSource.sections = sections

//            collectionView.reload(using: changeSet,
//                                  interrupt: { changeSet in
//                                      guard changeSet.sectionInserted.isEmpty else {
//                                          return true
//                                      }
//                                      return false
//                                  },
//                                  onInterruptedReload: {
//                                      let positionSnapshot = ChatLayoutPositionSnapshot(indexPath: IndexPath(item: 0, section: 0), kind: .footer, edge: .bottom)
//                                      self.collectionView.reloadData()
//                                      // We want so that user on reload appeared at the very bottom of the layout
//                                      self.chatLayout.restoreContentOffset(with: positionSnapshot)
//                                  },
//                                  completion: { _ in
//                                      completion?()
//                                  },
//                                  setData: { data in
//                                      self.dataSource.sections = data
//                                  })
        }

        if animated {
            process()
        } else {
            UIView.performWithoutAnimation {
                process()
            }
        }
    }

}

extension ChatViewController: InputBarAccessoryViewDelegate {

    public func inputBar(_ inputBar: InputBarAccessoryView, didChangeIntrinsicContentTo size: CGSize) {
        scrollToBottom()
    }

    public func inputBar(_ inputBar: InputBarAccessoryView, didPressSendButtonWith text: String) {
        let messageText = inputBar.inputTextView.text
        currentInterfaceActions.options.insert(.sendingMessage)
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) { [weak self] in
            guard let self = self else {
                return
            }
            guard let messageText = messageText else {
                self.currentInterfaceActions.options.remove(.sendingMessage)
                return
            }
            self.chatController.sendMessage(.text(messageText)) { sections in
                self.currentInterfaceActions.options.remove(.sendingMessage)
                self.processUpdates(with: sections, animated: true)
            }
        }
        inputBar.inputTextView.text = String()
        inputBar.invalidatePlugins()
    }

}

extension ChatViewController: KeyboardListenerDelegate {

    func keyboardWillChangeFrame(info: KeyboardInfo) {
        guard !currentInterfaceActions.options.contains(.changingFrameSize),
            collectionView.contentInsetAdjustmentBehavior != .never,
            let keyboardFrame = UIApplication.shared.keyWindow?.convert(info.frameEnd, to: view),
            collectionView.convert(collectionView.bounds, to: UIApplication.shared.keyWindow).maxY > info.frameEnd.minY else {
            return
        }
        currentInterfaceActions.options.insert(.changingKeyboardFrame)
        let newBottomInset = collectionView.frame.minY + collectionView.frame.size.height - keyboardFrame.minY - collectionView.safeAreaInsets.bottom
        if newBottomInset > 0,
            collectionView.contentInset.bottom != newBottomInset {
            let positionSnapshot = chatLayout.getContentOffsetSnapshot(from: .bottom)

            UIView.animate(withDuration: info.animationDuration, animations: {
//                self.collectionView.performBatchUpdates({
                    self.collectionView.contentInset.bottom = newBottomInset
                    self.collectionView.scrollIndicatorInsets.bottom = newBottomInset
//                }, completion: nil)

                if let positionSnapshot = positionSnapshot {
                    self.chatLayout.restoreContentOffset(with: positionSnapshot)
                }
                if #available(iOS 13.0, *) {
                } else {
                    // When contentInset is changed programmatically IOs 13 calls invalidate context automatically.
                    // this does not happen in ios 12 so we do it manually
                    self.collectionView.collectionViewLayout.invalidateLayout()
                }
            }, completion: { _ in
            })
        }
    }

    func keyboardDidChangeFrame(info: KeyboardInfo) {
        guard currentInterfaceActions.options.contains(.changingKeyboardFrame) else {
            return
        }
        currentInterfaceActions.options.remove(.changingKeyboardFrame)
    }

}
