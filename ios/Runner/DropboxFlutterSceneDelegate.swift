import Flutter
import ObjectiveDropboxOfficial
import UIKit

/// Intercepts Dropbox OAuth redirects (`db-*://…`) before Flutter deep-link routing.
class DropboxFlutterSceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    var passthrough = Set<UIOpenURLContext>()
    for context in URLContexts {
      if Self.handleDropboxRedirect(context.url) {
        continue
      }
      passthrough.insert(context)
    }
    if !passthrough.isEmpty {
      super.scene(scene, openURLContexts: passthrough)
    }
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    for context in connectionOptions.urlContexts {
      _ = Self.handleDropboxRedirect(context.url)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  /// Returns true when the URL was a Dropbox OAuth redirect.
  @discardableResult
  static func handleDropboxRedirect(_ url: URL) -> Bool {
    guard let scheme = url.scheme, scheme.hasPrefix("db-") else {
      return false
    }
    return DBClientsManager.handleRedirectURL(url) { authResult in
      guard let authResult else { return }
      if authResult.isSuccess() {
        NSLog("dropbox auth success")
      } else if authResult.isCancel() {
        NSLog("dropbox auth cancel")
      } else if authResult.isError() {
        NSLog(
          "dropbox auth error %@",
          String(describing: authResult.errorDescription)
        )
      }
    }
  }
}
