import CommonCrypto
import CryptoKit
import Foundation

/// Unwraps a `.rayconfig` down to its payload JSON, in either container Raycast has shipped.
enum RaycastDecoder {
    private struct Header: Decodable {
        struct Encryption: Decodable {
            let iv: String
            let salt: String
        }

        let schemaVersion: Int
        let encryption: Encryption
    }

    /// From the leading bytes alone, so a file is labelled before a passphrase is typed.
    static func isExport(_ raw: Data) -> Bool {
        raw.starts(with: magic) || looksSealed(raw)
    }

    /// The sealed file carries no signature, so block alignment past a header is the only signal.
    private static func looksSealed(_ raw: Data) -> Bool {
        raw.count >= sealedMinimumLength && raw.count % blockLength == 0
    }

    static func decrypt(_ raw: Data, passphrase: String) throws -> Data {
        if raw.starts(with: magic) { return try decryptContainer(raw, passphrase: passphrase) }
        guard looksSealed(raw) else { throw RaycastImportError.notRaycastFile }
        return try decryptSealed(raw, passphrase: passphrase)
    }

    /// Key from SHA256(passphrase), IV from SHA256(key + passphrase); CryptoKit has no CBC.
    private static func decryptSealed(_ raw: Data, passphrase: String) throws -> Data {
        let password = Data(passphrase.utf8)
        let first = Data(SHA256.hash(data: password))
        let second = Data(SHA256.hash(data: first + password))
        guard let plaintext = cbcDecrypt(raw, key: first, iv: second.prefix(16)),
            plaintext.count > randomHeaderLength
        else { throw RaycastImportError.incorrectPassphrase }
        do {
            return try Zlib.gunzip(
                plaintext.dropFirst(randomHeaderLength), maxOutput: maximumPayloadLength)
        } catch ZlibError.tooLarge {
            throw RaycastImportError.tooLarge
        } catch {
            throw RaycastImportError.incorrectPassphrase
        }
    }

    private static func cbcDecrypt(_ raw: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: raw.count + blockLength)
        var moved = 0
        let inCount = raw.count
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            raw.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                            inPtr.baseAddress, inCount, outPtr.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    private static func decryptContainer(_ raw: Data, passphrase: String) throws -> Data {
        guard isExport(raw) else { throw RaycastImportError.notRaycastFile }
        // `raw` can be a slice, so every offset below is measured from its own start.
        let base = raw.startIndex
        guard raw.count >= fixedHeaderLength else { throw RaycastImportError.corrupt }
        let headerLength =
            Int(raw[base + 8]) | Int(raw[base + 9]) << 8
            | Int(raw[base + 10]) << 16 | Int(raw[base + 11]) << 24
        guard headerLength > 0, headerLength <= maximumHeaderLength,
            fixedHeaderLength + headerLength <= raw.count
        else { throw RaycastImportError.corrupt }

        let payloadStart = base + fixedHeaderLength + headerLength
        let payloadEnd = raw.endIndex - authenticationTagLength
        guard payloadEnd > payloadStart,
            let headerJSON = try? Zlib.gunzip(
                raw[(base + fixedHeaderLength)..<payloadStart], maxOutput: maximumHeaderLength),
            let header = try? JSONDecoder().decode(Header.self, from: headerJSON),
            header.schemaVersion == containerSchemaVersion,
            let iv = Data(hex: header.encryption.iv), iv.count == ivLength,
            let salt = Data(hex: header.encryption.salt), salt.count == saltLength
        else { throw RaycastImportError.corrupt }

        let key = Scrypt.derive(
            passphrase: Array(passphrase.utf8), salt: [UInt8](salt),
            n: 16384, r: 8, p: 1, dkLen: 32)
        let payloadGzip: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: iv),
                ciphertext: raw[payloadStart..<payloadEnd],
                tag: raw[payloadEnd...])
            payloadGzip = try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw RaycastImportError.incorrectPassphrase
        }

        do {
            return try Zlib.gunzip(payloadGzip, maxOutput: maximumPayloadLength)
        } catch ZlibError.tooLarge {
            throw RaycastImportError.tooLarge
        } catch {
            throw RaycastImportError.corrupt
        }
    }

    private static let magic = Data("RAYCFG3\n".utf8)
    private static let containerSchemaVersion = 3
    private static let fixedHeaderLength = 12
    private static let blockLength = 16
    private static let randomHeaderLength = 16
    private static let sealedMinimumLength = randomHeaderLength + 2 * blockLength
    private static let maximumHeaderLength = 1024 * 1024
    // AES already authenticated this stream; the cap is only a memory bound.
    private static let maximumPayloadLength = 512 * 1024 * 1024
    private static let authenticationTagLength = 16
    private static let ivLength = 16
    private static let saltLength = 16
}

extension Data {
    /// Parses an even-length hex string; returns nil on any non-hex character.
    fileprivate init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)

        func nibble(_ char: UInt8) -> UInt8? {
            switch char {
            case 0x30...0x39: return char - 0x30
            case 0x61...0x66: return char - 0x61 + 10
            case 0x41...0x46: return char - 0x41 + 10
            default: return nil
            }
        }

        var index = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self = Data(bytes)
    }
}
