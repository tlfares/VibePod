import Foundation

/// The app's long-lived models, created once per launch; `ContentView`
/// shows them.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let libraryService: LibraryService
    let libraryVM: LibraryViewModel
    let playerVM: PlayerViewModel
    let importService: FileImportService

    private init() {
        let libraryService = LibraryService()
        let playerService = MusicPlayerService.shared
        playerService.restoreState(with: libraryService.songs)

        self.libraryService = libraryService
        libraryVM = LibraryViewModel(libraryService: libraryService)
        playerVM = PlayerViewModel(playerService: playerService, libraryService: libraryService)
        importService = FileImportService(libraryService: libraryService)
        SubsonicService.shared.start(with: libraryService)
        CloudSync.shared.start(library: libraryService)
    }
}
