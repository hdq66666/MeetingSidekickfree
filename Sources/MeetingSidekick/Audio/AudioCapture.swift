import Foundation

protocol AudioCapture: AnyObject {
    var onFrame: ((Data) -> Void)? { get set }
    func stop()
}
