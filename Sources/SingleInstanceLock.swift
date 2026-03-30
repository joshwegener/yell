import Foundation
import Darwin

final class SingleInstanceLock {
    private let fileDescriptor: Int32

    init?(name: String = "com.yell.app.lock") {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        fileDescriptor = open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor != -1 else { return nil }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDescriptor)
            return nil
        }
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
