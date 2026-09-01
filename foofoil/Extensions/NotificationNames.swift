//  NotificationNames.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//


import Foundation

extension Notification.Name {
    public static let webSnapshotReadyForSave = Notification.Name("webSnapshotReadyForSave")
    public static let createNewFoofoilFromImage = Notification.Name("createNewFoofoilFromImage")
    public static let shouldRestoreFrame = Notification.Name("shouldRestoreFrame")
    public static let shouldFitImageToWindowWidth = Notification.Name("shouldFitImageToWindowWidth")
    public static let shouldZoomIn = Notification.Name("shouldZoomIn")
    public static let shouldCloseWindow = Notification.Name("shouldCloseWindow")
    public static let shouldFitWindowToImage = Notification.Name("shouldFitWindowToImage")
    public static let shouldResizeWindowWithPinch = Notification.Name("shouldResizeWindowWithPinch")
    public static let shouldEndWindowPinchResize = Notification.Name("shouldEndWindowPinchResize")
    public static let shouldResetWindowFrame = Notification.Name("shouldResetWindowFrame")
    public static let willResetContent = Notification.Name("willResetContent")
    public static let showBorderDidChange = Notification.Name("showBorderDidChange")
    public static let shouldGoToPreviousPDFPage = Notification.Name("shouldGoToPreviousPDFPage")
    public static let shouldGoToNextPDFPage = Notification.Name("shouldGoToNextPDFPage")
    public static let shouldPromptForPDFPage = Notification.Name("shouldPromptForPDFPage")
    public static let pdfPageSizeDidChange = Notification.Name("pdfPageSizeDidChange")
    public static let pdfPageDidChange = Notification.Name("pdfPageDidChange")
    public static let shouldFitPDFToWindow = Notification.Name("shouldFitPDFToWindow")
    public static let shouldMatchPDFWindowAspectRatio = Notification.Name("shouldMatchPDFWindowAspectRatio")
    public static let shouldApplyPDFScaleToWindow = Notification.Name("shouldApplyPDFScaleToWindow")
    public static let shouldToggleVideoPlayback = Notification.Name("shouldToggleVideoPlayback")
    public static let mediaPlaybackDidFinish = Notification.Name("mediaPlaybackDidFinish")
    public static let mediaPresentationSizeDidChange = Notification.Name("mediaPresentationSizeDidChange")
    public static let openGroupedFiles = Notification.Name("openGroupedFiles")
    public static let imageListSlideshowIntervalDidChange = Notification.Name("imageListSlideshowIntervalDidChange")
    public static let mediaPlaybackControlsAutoHideIntervalDidChange = Notification.Name("mediaPlaybackControlsAutoHideIntervalDidChange")
    public static let showsMediaBottomProgressBarDidChange = Notification.Name("showsMediaBottomProgressBarDidChange")
}
