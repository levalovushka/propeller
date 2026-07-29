import AudioToolbox
import CoreAudio
import Foundation

/// Чтение свойств Core Audio без четырёх строк церемонии на каждое.
///
/// Пространство имён, а не `extension AudioObjectID`: `AudioObjectID` — это
/// `UInt32`, и расширять его значит навесить `readDeviceUID()` на каждое целое
/// число в модуле.
enum CoreAudioObjects {

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: - Примитивы

    static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default fallback: T,
        qualifier: UnsafeRawPointer? = nil,
        qualifierSize: UInt32 = 0
    ) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = fallback
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            AudioObjectGetPropertyData(object, &addr, qualifierSize, qualifier, &size, ptr)
        }
        return status == noErr ? result : nil
    }

    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func objectList(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func stringList(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> [String] {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFArray?>.size)
        var value: CFArray?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? String }
    }

    // MARK: - Устройства

    static var defaultOutputDevice: AudioDeviceID? {
        let id = value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            default: AudioDeviceID(kAudioObjectUnknown)
        )
        return (id.map { $0 != AudioDeviceID(kAudioObjectUnknown) } ?? false) ? id : nil
    }

    static var defaultInputDevice: AudioDeviceID? {
        let id = value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice,
            default: AudioDeviceID(kAudioObjectUnknown)
        )
        return (id.map { $0 != AudioDeviceID(kAudioObjectUnknown) } ?? false) ? id : nil
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioDeviceID) -> String {
        string(device, kAudioObjectPropertyName) ?? "устройство #\(device)"
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        value(device, kAudioDevicePropertyNominalSampleRate, default: Double(0)).flatMap {
            $0 > 0 ? $0 : nil
        }
    }

    /// Сколько входных каналов у устройства. Именно оно решает, где во входном
    /// буфере агрегата начинается следующий источник (`CaptureChannelLayout`).
    static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        channelCount(device, scope: kAudioObjectPropertyScopeInput)
    }

    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Процессы

    static var processList: [AudioObjectID] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    static func processBundleID(_ process: AudioObjectID) -> String? {
        let bundleID = string(process, kAudioProcessPropertyBundleID)
        return (bundleID?.isEmpty ?? true) ? nil : bundleID
    }

    static func processPID(_ process: AudioObjectID) -> pid_t? {
        value(process, kAudioProcessPropertyPID, default: pid_t(-1)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var object = AudioObjectID(kAudioObjectUnknown)
        let status = withUnsafeMutablePointer(to: &pidValue) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<pid_t>.size), qualifier,
                &size, &object
            )
        }
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }

    // MARK: - Тап и агрегат

    static func tapStreamFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
    }

    /// Сабдевайсы агрегата в том порядке, в каком их вернула система. Читается
    /// после сборки, а не берётся из нашей же композиции: раскладка каналов
    /// считается от **фактического** состава, иначе первая же неучтённая
    /// перестановка отправит микрофон в системную дорожку.
    static func aggregateSubDeviceUIDs(_ aggregate: AudioObjectID) -> [String] {
        let byUID = stringList(aggregate, kAudioAggregateDevicePropertyFullSubDeviceList)
        if !byUID.isEmpty { return byUID }
        // Часть систем отвечает объектами, а не UID-ами.
        return objectList(aggregate, kAudioAggregateDevicePropertyFullSubDeviceList)
            .compactMap { deviceUID($0) }
    }
}
