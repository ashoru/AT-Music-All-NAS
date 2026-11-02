import UIKit

/// 复用本地图片解码结果，避免设置页/歌词页滚动时反复从磁盘解码大图。
enum ATMusicImageFileCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 60 * 1024 * 1024 // 60 MB 显存硬顶
        c.countLimit = 100
        return c
    }()

    static func image(at path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? (Int(image.size.width * image.size.height) * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    static func remove(_ path: String) {
        guard !path.isEmpty else { return }
        cache.removeObject(forKey: path as NSString)
    }

    static func removeAll() {
        cache.removeAllObjects()
    }
}
