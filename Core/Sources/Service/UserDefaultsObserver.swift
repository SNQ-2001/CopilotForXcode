import Foundation

final class UserDefaultsObserver: NSObject {
    var onChange: (() -> Void)?
    private weak var object: NSObject?
    private let keyPaths: [String]
    
    init(object: NSObject, forKeyPaths keyPaths: [String], context: UnsafeMutableRawPointer?) {
        self.object = object
        self.keyPaths = keyPaths
        super.init()
        for keyPath in keyPaths {
            object.addObserver(self, forKeyPath: keyPath, options: .new, context: context)
        }
    }

    deinit {
        for keyPath in keyPaths {
            object?.removeObserver(self, forKeyPath: keyPath)
        }
    }
    
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        onChange?()
    }
}
