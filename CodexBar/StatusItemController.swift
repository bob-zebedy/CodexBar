//
//  StatusItemController.swift
//  CodexBar
//
//  Created by Bob on 2026-06-14.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class CodexBarAppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = RateLimitsViewModel()
    let appUpdater = AppUpdater()
    
    private var statusItemController: StatusItemController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(viewModel: viewModel, appUpdater: appUpdater)
        controller.install()
        statusItemController = controller
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.uninstall()
    }
}

@MainActor
private final class StatusItemController: NSObject {
    private let viewModel: RateLimitsViewModel
    private let appUpdater: AppUpdater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    
    private var settingsWindow: NSWindow?
    private var deferredRefreshTask: Task<Void, Never>?
    private var popoverOpenTask: Task<Void, Never>?
    private var popoverCloseTask: Task<Void, Never>?
    private var popoverState = PopoverState.hidden
    private var popoverAnimationGeneration = 0
    private var localMouseEventMonitor: Any?
    private var globalMouseEventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var lastHasError: Bool?

    private static let normalImage = NSImage(systemSymbolName: "person.fill.checkmark", accessibilityDescription: nil)
    private static let errorImage = NSImage(systemSymbolName: "person.fill.xmark", accessibilityDescription: nil)
    
    init(viewModel: RateLimitsViewModel, appUpdater: AppUpdater) {
        self.viewModel = viewModel
        self.appUpdater = appUpdater
        super.init()
    }
    
    func install() {
        configureStatusButton()
        configurePopover()
        observeViewModel()
        updateStatusImage()
        viewModel.startAutoRefresh()
    }
    
    func uninstall() {
        closePopover(animated: false)
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
    
    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }
        
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.imagePosition = .imageOnly
        button.toolTip = "CodexBar"
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    
    private func configurePopover() {
        let rootView = RateLimitsMenuView(viewModel: viewModel)
            .environmentObject(appUpdater)
            .frame(width: RateLimitsMenuView.menuWidth)
        
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = hostingController
    }
    
    private func observeViewModel() {
        viewModel.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateStatusImage()
                }
            }
            .store(in: &cancellables)
    }
    
    private func updateStatusImage() {
        let hasError = viewModel.hasError
        guard hasError != lastHasError else {
            return
        }

        lastHasError = hasError
        statusItem.button?.image = hasError ? Self.errorImage : Self.normalImage
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApplication.shared.currentEvent else {
            togglePopover(relativeTo: sender)
            return
        }
        
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(relativeTo: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }
    
    private func togglePopover(relativeTo button: NSStatusBarButton) {
        switch popoverState {
        case .hidden:
            openPopover(relativeTo: button)
        case .opening, .shown:
            closePopover()
        case .closing:
            finishPopoverClose()
            openPopover(relativeTo: button)
        }
    }
    
    private func cancelPopoverTasks() {
        deferredRefreshTask?.cancel()
        deferredRefreshTask = nil
        popoverOpenTask?.cancel()
        popoverOpenTask = nil
        popoverCloseTask?.cancel()
        popoverCloseTask = nil
    }

    private func openPopover(relativeTo button: NSStatusBarButton) {
        cancelPopoverTasks()

        popoverAnimationGeneration += 1
        let generation = popoverAnimationGeneration
        popoverState = .opening
        
        preparePopoverForFadeIn()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        stabilizePopoverChromeAppearance()
        installPopoverDismissMonitors()
        fadePopover(to: 1, duration: Metrics.fadeInDuration)
        
        popoverOpenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Metrics.fadeInDuration * 1000)))
            guard let self, !Task.isCancelled, self.popoverAnimationGeneration == generation else {
                return
            }
            
            self.resetPopoverAlpha()
            self.popoverState = .shown
            self.popoverOpenTask = nil
        }
        
        scheduleDeferredRefresh()
    }
    
    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        closePopover(animated: false)
        
        let menu = NSMenu()
        
        let settingsItem = NSMenuItem(
            title: "设置",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitItem.target = self
        menu.addItem(quitItem)
        
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
    }
    
    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        
        guard let settingsWindow else {
            return
        }
        
        NSApplication.shared.activate()
        prepareSettingsWindowForDisplay(settingsWindow)
        settingsWindow.makeKeyAndOrderFront(nil)
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    private func closePopover(animated: Bool = true) {
        if popoverState == .closing && animated {
            return
        }
        
        cancelPopoverTasks()
        removePopoverDismissMonitors()

        guard popover.isShown else {
            resetPopoverAlpha()
            popoverState = .hidden
            return
        }
        
        guard animated, let contentView = popover.contentViewController?.view else {
            finishPopoverClose()
            return
        }
        
        popoverAnimationGeneration += 1
        let generation = popoverAnimationGeneration
        popoverState = .closing
        
        let popoverWindow = contentView.window
        fadePopover(to: 0, duration: Metrics.fadeOutDuration)
        popoverCloseTask = Task { @MainActor [weak self, weak contentView, weak popoverWindow] in
            try? await Task.sleep(for: .milliseconds(Int(Metrics.fadeOutDuration * 1000)))
            guard let self, !Task.isCancelled, self.popoverAnimationGeneration == generation else {
                return
            }
            
            self.popover.performClose(nil)
            contentView?.alphaValue = 1
            popoverWindow?.alphaValue = 1
            self.popoverState = .hidden
            self.popoverCloseTask = nil
        }
    }
    
    private func finishPopoverClose() {
        cancelPopoverTasks()
        popoverAnimationGeneration += 1
        removePopoverDismissMonitors()
        
        if popover.isShown {
            popover.performClose(nil)
        }
        
        resetPopoverAlpha()
        popoverState = .hidden
    }
    
    private func installPopoverDismissMonitors() {
        removePopoverDismissMonitors()
        
        localMouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: Metrics.dismissEventMask) { [weak self] event in
            self?.closePopoverIfNeeded(for: event)
            self?.restabilizePopoverChromeAfterEvent()
            return event
        }
        
        globalMouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: Metrics.dismissEventMask) { [weak self] _ in
            self?.closePopover()
        }
    }
    
    private func removePopoverDismissMonitors() {
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
            self.localMouseEventMonitor = nil
        }
        
        if let globalMouseEventMonitor {
            NSEvent.removeMonitor(globalMouseEventMonitor)
            self.globalMouseEventMonitor = nil
        }
    }
    
    private func restabilizePopoverChromeAfterEvent() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.popover.isShown else {
                return
            }
            
            self.stabilizePopoverChromeAppearance()
        }
    }
    
    private func stabilizePopoverChromeAppearance() {
        guard let rootView = popover.contentViewController?.view.window?.contentView else {
            return
        }
        
        stabilizeVisualEffectViews(in: rootView)
    }
    
    private func stabilizeVisualEffectViews(in view: NSView) {
        if let visualEffectView = view as? NSVisualEffectView {
            visualEffectView.state = .inactive
            visualEffectView.isEmphasized = false
        }
        
        for subview in view.subviews {
            stabilizeVisualEffectViews(in: subview)
        }
    }
    
    private func closePopoverIfNeeded(for event: NSEvent) {
        guard popover.isShown else {
            return
        }
        
        if isEventInsidePopover(event) || isEventInsideStatusButton(event) {
            return
        }
        
        closePopover()
    }
    
    private func isEventInsidePopover(_ event: NSEvent) -> Bool {
        guard let contentView = popover.contentViewController?.view,
              event.window == contentView.window else {
            return false
        }
        
        let point = contentView.convert(event.locationInWindow, from: nil)
        return contentView.bounds.contains(point)
    }
    
    private func isEventInsideStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button,
              let buttonWindow = button.window else {
            return false
        }
        
        let eventScreenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonRectInWindow)
        return buttonScreenRect.contains(eventScreenPoint)
    }
    
    private func preparePopoverForFadeIn() {
        popover.contentViewController?.view.alphaValue = 0
        popover.contentViewController?.view.window?.alphaValue = 0
    }
    
    private func resetPopoverAlpha() {
        popover.contentViewController?.view.alphaValue = 1
        popover.contentViewController?.view.window?.alphaValue = 1
    }
    
    private func fadePopover(to alpha: CGFloat, duration: TimeInterval) {
        guard let contentView = popover.contentViewController?.view else {
            return
        }
        
        let popoverWindow = contentView.window
        // 淡入前窗口可能刚由 popover.show 懒创建,先把窗口 alpha 归零再动画
        if alpha == 1 {
            popoverWindow?.alphaValue = 0
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            popoverWindow?.animator().alphaValue = alpha
            contentView.animator().alphaValue = alpha
        }
    }
    
    private func scheduleDeferredRefresh() {
        deferredRefreshTask?.cancel()
        deferredRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled, self.popover.isShown else {
                return
            }
            
            self.viewModel.refreshIfNeeded()
        }
    }
    
    private func makeSettingsWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppSettingsView()
                .environmentObject(appUpdater)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "CodexBar 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        return window
    }
    
    private func prepareSettingsWindowForDisplay(_ window: NSWindow) {
        window.contentViewController?.view.layoutSubtreeIfNeeded()
        
        if let fittingSize = window.contentViewController?.view.fittingSize,
           fittingSize.width > 0,
           fittingSize.height > 0 {
            window.setContentSize(fittingSize)
        }
        
        centerSettingsWindow(window)
    }
    
    private func centerSettingsWindow(_ window: NSWindow) {
        guard let screen = statusItem.button?.window?.screen ?? window.screen ?? NSScreen.main else {
            window.center()
            return
        }
        
        let visibleFrame = screen.visibleFrame
        let windowFrame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - windowFrame.width / 2,
            y: visibleFrame.midY - windowFrame.height / 2
        )
        
        window.setFrameOrigin(origin)
    }
    
    private enum Metrics {
        static let dismissEventMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        static let fadeInDuration: TimeInterval = 0.24
        static let fadeOutDuration: TimeInterval = 0.18
    }
    
    private enum PopoverState {
        case hidden
        case opening
        case shown
        case closing
    }
}
