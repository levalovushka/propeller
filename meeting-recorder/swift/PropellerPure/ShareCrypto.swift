import Compression
import CryptoKit
import Foundation

/// # Шифрование того, что уезжает по ссылке
///
/// Единственное место, где держится обещание «сервер не видит содержимого»
/// (`SERVER.md` §3). Ключ рождается здесь, здесь же и остаётся: наружу уходят
/// только байты, а ключ едет во фрагменте ссылки, которого сервер не получает.
///
/// Лежит в чистом слое не для красоты, а потому что круг «сжали → зашифровали →
/// расшифровали → разжали» — единственное, что вообще можно проверить тестом.
/// Сеть и Keychain проверить нечем, и они остались в приложении.
public enum ShareCrypto {

    public struct Sealed: Equatable {
        /// `nonce (12) ‖ шифротекст ‖ тег (16)` — ровно `AES.GCM.SealedBox.combined`
        /// и ровно то, что вьюер отдаёт в WebCrypto.
        public let blob: Data
        public let key: Data
    }

    public enum Failure: Error {
        case compression
        case encryption
    }

    /// Сжать, потом зашифровать — не наоборот: шифротекст не сжимается.
    ///
    /// Сжатие — «сырой DEFLATE» (`COMPRESSION_ZLIB` у Apple означает именно
    /// его, без заголовка zlib), потому что у браузера есть ровно такой
    /// разжиматель: `DecompressionStream('deflate-raw')`. Gzip потребовал бы
    /// собирать заголовок и CRC руками ради того же результата.
    public static func seal(_ plaintext: Data) throws -> Sealed {
        let deflated = try deflate(plaintext)
        let key = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(deflated, using: key)
        guard let combined = box.combined else { throw Failure.encryption }
        return Sealed(blob: combined, key: key.withUnsafeBytes { Data($0) })
    }

    /// Обратный ход нужен только тесту: приложение свои шеры не читает, их
    /// читает браузер. Но круг, который никто не проходит, — это круг, про
    /// который неизвестно, замкнут ли он.
    public static func open(blob: Data, key: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: blob)
        let deflated = try AES.GCM.open(box, using: SymmetricKey(data: key))
        return try inflate(deflated)
    }

    // MARK: - DEFLATE

    public static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw Failure.compression }
        // Запас на несжимаемый вход: DEFLATE в худшем случае чуть длиннее
        // исходника, и буфер «ровно по размеру» молча вернул бы ноль.
        let capacity = data.count + 4096
        var out = Data(count: capacity)

        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw Failure.compression }
        out.removeSubrange(written..<capacity)
        return out
    }

    public static func inflate(_ data: Data) throws -> Data {
        var capacity = max(data.count * 8, 64 * 1024)
        for _ in 0..<6 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src -> Int in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            // Ровно заполненный буфер неотличим от переполненного: и то и
            // другое — `written == capacity`. Поэтому растём и пробуем снова.
            if written > 0, written < capacity {
                out.removeSubrange(written..<capacity)
                return out
            }
            capacity *= 4
        }
        throw Failure.compression
    }
}
