import Foundation
import Speech

/// Locale reservation and model installation, shared by the batch and live
/// transcribers.
enum SpeechModel {

    enum Failure: LocalizedError {
        case localeUnsupported(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let identifier):
                return "On-device transcription isn't available for \(identifier)."
            case .unavailable(let detail):
                return "Couldn't install the speech model. \(detail)"
            }
        }
    }

    /// Resolve a requested language to one the framework actually supports.
    static func resolveLocale(_ locale: Locale) async throws -> Locale {
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.localeUnsupported(locale.identifier)
        }
        return resolved
    }

    /// Reserve the locale, and install its model if it isn't present.
    ///
    /// **Reservation and installation are separate concerns.** A reservation is
    /// what permits a module to *be used*; installation merely puts the model on
    /// disk. Reserving only when a download was needed left the analyzer
    /// unusable — `Cannot use modules with unallocated locales [...] Currently
    /// allocated locales are []` — producing no results and never terminating.
    /// Always reserve.
    static func prepare(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let target = locale.identifier(.bcp47)

        do {
            let reserved = await AssetInventory.reservedLocales
            if reserved.contains(where: { $0.identifier(.bcp47) == target }) {
                TranscribeLog.log("locale \(target) already reserved")
            } else {
                let maximum = AssetInventory.maximumReservedLocales
                if reserved.count >= maximum, let oldest = reserved.first {
                    TranscribeLog.log("reservations full (\(maximum)), releasing "
                        + oldest.identifier(.bcp47))
                    await AssetInventory.release(reservedLocale: oldest)
                }
                let granted = try await AssetInventory.reserve(locale: locale)
                TranscribeLog.log("reserved \(target) → \(granted)")
                guard granted else {
                    throw Failure.unavailable("Couldn't reserve \(target).")
                }
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unavailable(error.localizedDescription)
        }

        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == target }) {
            TranscribeLog.log("model for \(target) already installed")
            return
        }

        TranscribeLog.log("installing speech model for \(target) — first run for this language")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            TranscribeLog.log("model installed")
        } catch {
            throw Failure.unavailable(error.localizedDescription)
        }
    }
}
