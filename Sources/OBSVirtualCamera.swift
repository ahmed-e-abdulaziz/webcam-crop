// Feeds frames into the OBS Virtual Camera system extension (only the extension is used;
// the OBS app itself must not be running its own virtual camera).
import CoreMedia
import CoreMediaIO
import Foundation

let obsDeviceUID = "7626645E-4425-469E-9D8B-97E0FA59AC75"  // fixed UID of OBS's camera extension
let obsBundleID = "com.obsproject.obs-studio"

private func address(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(selector),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

final class OBSVirtualCamera {
    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?

    static func findDevice() -> CMIOObjectID? {
        var addr = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0, used: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices)
        var uidAddr = address(kCMIODevicePropertyDeviceUID)
        for d in devices {
            var uid: Unmanaged<CFString>?
            let sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if CMIOObjectGetPropertyData(d, &uidAddr, 0, nil, sz, &used, &uid) == noErr,
               let u = uid?.takeRetainedValue() as String?, u == obsDeviceUID {
                return d
            }
        }
        return nil
    }

    init() throws {
        guard let dev = Self.findDevice() else {
            throw Self.error("OBS Virtual Camera driver not found. Keep OBS installed (open it once and start/stop its Virtual Camera).")
        }
        deviceID = dev
        var addr = address(kCMIODevicePropertyStreams)
        var size: UInt32 = 0, used: UInt32 = 0
        CMIOObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        var streams = [CMIOStreamID](repeating: 0, count: Int(size) / MemoryLayout<CMIOStreamID>.size)
        CMIOObjectGetPropertyData(deviceID, &addr, 0, nil, size, &used, &streams)
        guard streams.count >= 2 else { throw Self.error("OBS Virtual Camera input stream not found.") }
        streamID = streams[1]  // [0] = what apps read, [1] = sink we write into

        var q: Unmanaged<CMSimpleQueue>?
        let st = CMIOStreamCopyBufferQueue(streamID, { _, _, _ in }, nil, &q)
        guard st == noErr, let qq = q?.takeRetainedValue() else {
            throw Self.error("Could not open the virtual camera (\(st)).")
        }
        queue = qq
        let r = CMIODeviceStartStream(deviceID, streamID)
        guard r == noErr else {
            throw Self.error("Could not start the virtual camera (\(r)). Quit OBS if it is open.")
        }
    }

    func send(_ sample: CMSampleBuffer) {
        guard let queue else { return }
        if CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue) { return }  // consumer behind: drop
        let ptr = Unmanaged.passRetained(sample).toOpaque()
        if CMSimpleQueueEnqueue(queue, element: ptr) != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(ptr).release()
        }
    }

    func stop() {
        if deviceID != 0 && streamID != 0 { CMIODeviceStopStream(deviceID, streamID) }
        streamID = 0
        queue = nil
    }

    private static func error(_ msg: String) -> NSError {
        NSError(domain: "WebcamCrop", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
