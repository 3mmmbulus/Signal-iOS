//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

// Used to represent undo/redo operations.
//
// Because the image editor's "contents" and "items"
// are immutable, these operations simply take a
// snapshot of the current contents which can be used
// (multiple times) to preserve/restore editor state.
private struct ImageEditorOperation {

    let operationId: String

    let contents: ImageEditorContents

    init(contents: ImageEditorContents) {
        self.operationId = UUID().uuidString
        self.contents = contents
    }
}

// MARK: -

protocol ImageEditorModelObserver: AnyObject {
    // Used for large changes to the model, when the entire
    // model should be reloaded.
    func imageEditorModelDidChange(
        before: ImageEditorContents,
        after: ImageEditorContents,
    )

    // Used for small narrow changes to the model, usually
    // to a single item.
    func imageEditorModelDidChange(changedItemIds: [String])
}

// MARK: -

@MainActor
class ImageEditorModel {

    let srcImage: NormalizedImage
    let srcImageSizePixels: CGSize
    let srcImageMetadata: ImageMetadata

    private var contents: ImageEditorContents

    private var transform: ImageEditorTransform

    private var undoStack = [ImageEditorOperation]()
    private var redoStack = [ImageEditorOperation]()

    typealias StickerImageCache = LRUCache<String, ThreadSafeCacheHandle<UIImage>>
    var stickerViewCache = StickerImageCache(maxSize: 16, shouldEvacuateInBackground: true)

    var blurredSourceImage: CGImage?

    /// Tellomi（tellomi/tellomi#1522 E-2）：橡皮用原图搭底图，每动一下都要重搭；原图解码一次留在模型上，跟着模型一起释放。
    var tellomiDecodedSrcImage: UIImage?

    /// Tellomi（tellomi/tellomi#1592 E5-2）：调色后的底图缓存（预览、发出、打码各一份），见 `ImageEditorCanvasView+TellomiAdjustments.swift`。
    var tellomiAdjustedImages = TellomiAdjustedImageCache()

    var color = ColorPickerBarColor.defaultColor

    init(normalizedImage: NormalizedImage) throws {
        self.srcImage = normalizedImage
        let srcImageMetadata = try normalizedImage.dataSource.imageSource().imageMetadata()
        guard let srcImageMetadata else {
            throw ImageEditorError.invalidInput
        }
        self.srcImageMetadata = srcImageMetadata
        let srcImageSizePixels = srcImageMetadata.pixelSize
        guard srcImageSizePixels.width > 0, srcImageSizePixels.height > 0 else {
            throw ImageEditorError.invalidInput
        }
        self.srcImageSizePixels = srcImageSizePixels

        self.contents = ImageEditorContents()
        self.transform = ImageEditorTransform.defaultTransform(srcImageSizePixels: srcImageSizePixels)
    }

    func renderOutput() -> UIImage? {
        ImageEditorCanvasView.renderForOutput(model: self, transform: currentTransform())
    }

    func currentTransform() -> ImageEditorTransform {
        transform
    }

    var isDirty: Bool {
        if itemCount > 0 {
            return true
        }
        // Tellomi（#1591 E5-1）：调过色也算编辑过（高清项、发出时重新渲染）
        if !contents.adjustments.isDefault {
            return true
        }
        return transform != ImageEditorTransform.defaultTransform(srcImageSizePixels: srcImageSizePixels)
    }

    var itemCount: Int {
        contents.itemCount
    }

    /// Tellomi（#1591 E5-1）：这张照片的调色。
    var adjustments: TellomiImageAdjustments {
        contents.adjustments
    }

    /// Tellomi（#1591 E5-1）：换调色；和当前一样就什么都不做。拖滑杆时第一下不带 `suppressUndo`（撤销栈记下拖之前的样子），
    /// 之后拖动中都带上，一次拖动只占一步撤销（同 `ImageEditorView` 拖贴纸调 `replace(item:suppressUndo:)` 的做法）。
    /// 走整份重载（`changedItemIds: nil`），因为调色改的是底图，不是某一个元素。
    func replace(adjustments: TellomiImageAdjustments, suppressUndo: Bool = false) {
        guard adjustments != contents.adjustments else { return }
        performAction(
            { oldContents in
                var newContents = oldContents
                newContents.adjustments = adjustments
                return newContents
            },
            changedItemIds: nil,
            suppressUndo: suppressUndo,
        )
    }

    var items: [ImageEditorItem] {
        contents.items
    }

    var itemIds: [String] {
        contents.itemIds
    }

    func has(itemForId itemId: String) -> Bool {
        item(forId: itemId) != nil
    }

    func item(forId itemId: String) -> ImageEditorItem? {
        contents.item(forId: itemId)
    }

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    var currentUndoOperationId: String? {
        undoStack.last?.operationId
    }

    // MARK: - Observers

    private var observers = [Weak<ImageEditorModelObserver>]()

    func add(observer: ImageEditorModelObserver) {
        observers.append(Weak(value: observer))
    }

    private func fireModelDidChange(
        before: ImageEditorContents,
        after: ImageEditorContents,
    ) {
        // We could diff here and yield a more narrow change event.
        for weakObserver in observers {
            guard let observer = weakObserver.value else {
                continue
            }
            observer.imageEditorModelDidChange(
                before: before,
                after: after,
            )
        }
    }

    private func fireModelDidChange(changedItemIds: [String]) {
        // We could diff here and yield a more narrow change event.
        for weakObserver in observers {
            guard let observer = weakObserver.value else {
                continue
            }
            observer.imageEditorModelDidChange(changedItemIds: changedItemIds)
        }
    }

    // MARK: -

    func undo() {
        guard let undoOperation = undoStack.popLast() else {
            owsFailDebug("Cannot undo.")
            return
        }

        let redoOperation = ImageEditorOperation(contents: contents)
        redoStack.append(redoOperation)

        let oldContents = contents
        contents = undoOperation.contents

        // We could diff here and yield a more narrow change event.
        fireModelDidChange(before: oldContents, after: contents)
    }

    func redo() {
        guard let redoOperation = redoStack.popLast() else {
            owsFailDebug("Cannot redo.")
            return
        }

        let undoOperation = ImageEditorOperation(contents: contents)
        undoStack.append(undoOperation)

        let oldContents = contents
        contents = redoOperation.contents

        // We could diff here and yield a more narrow change event.
        fireModelDidChange(before: oldContents, after: contents)
    }

    func append(item: ImageEditorItem) {
        performAction(
            { oldContents in
                var newContents = oldContents
                newContents.append(item: item)
                return newContents
            },
            changedItemIds: [item.itemId],
        )
    }

    func replace(item: ImageEditorItem, suppressUndo: Bool = false) {
        performAction(
            { oldContents in
                var newContents = oldContents
                newContents.replace(item: item)
                return newContents
            },
            changedItemIds: [item.itemId],
            suppressUndo: suppressUndo,
        )
    }

    func remove(item: ImageEditorItem) {
        performAction(
            { oldContents in
                var newContents = oldContents
                newContents.remove(item: item)
                return newContents
            },
            changedItemIds: [item.itemId],
        )
    }

    func replace(transform: ImageEditorTransform) {
        self.transform = transform

        // The contents haven't changed, but this event prods the
        // observers to reload everything, which is necessary if
        // the transform changes.
        fireModelDidChange(before: contents, after: contents)
    }

    // MARK: - Temp Files

    private var temporaryFilePaths = [String]()

    func temporaryFilePath(fileExtension: String) -> String {
        AssertIsOnMainThread()

        let filePath = OWSFileSystem.temporaryFilePath(
            fileExtension: fileExtension,
            isAvailableWhileDeviceLocked: false,
        )
        temporaryFilePaths.append(filePath)
        return filePath
    }

    deinit {
        AssertIsOnMainThread()

        let temporaryFilePaths = self.temporaryFilePaths

        DispatchQueue.sharedUtility.async {
            for filePath in temporaryFilePaths {
                guard OWSFileSystem.deleteFile(filePath) else {
                    Logger.error("Could not delete temp file: \(filePath)")
                    continue
                }
            }
        }
    }

    private func performAction(
        _ action: (ImageEditorContents) -> ImageEditorContents,
        changedItemIds: [String]?,
        suppressUndo: Bool = false,
    ) {
        if !suppressUndo {
            let undoOperation = ImageEditorOperation(contents: contents)
            undoStack.append(undoOperation)
            redoStack.removeAll()
        }

        let oldContents = contents
        let newContents = action(oldContents)
        contents = newContents

        if let changedItemIds {
            fireModelDidChange(changedItemIds: changedItemIds)
        } else {
            fireModelDidChange(
                before: oldContents,
                after: contents,
            )
        }
    }
}
