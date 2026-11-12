import ABSCore
import Foundation

/// The server's email routes the app uses (server `EmailController`).
public enum EmailEndpoints {
    /// `POST /api/emails/send-ebook-to-device`: emails the item's primary ebook
    /// (`media.ebookFile`) to the e-reader device named `deviceName`, one of the
    /// ``AuthResponse/ereaderDevices`` the server sent for this user. The server replies 404 with
    /// text when the device, item or ebook isn't found, 403 when the user can't use the device or
    /// item, and 400 with the mailer's error text when sending fails.
    ///
    /// Only redirects on the server's origin are followed (``Endpoint/staysOnOrigin``): a 307 or
    /// 308 elsewhere would re-post the item and device to another host and report its reply as a
    /// successful send.
    public static func sendEbookToDevice(libraryItemID: String, deviceName: String) -> Endpoint<EmptyResponse> {
        Endpoint(
            .post, "/api/emails/send-ebook-to-device",
            body: SendEbookBody(libraryItemId: libraryItemID, deviceName: deviceName), staysOnOrigin: true)
    }

    private struct SendEbookBody: Encodable, Sendable {
        let libraryItemId: String
        let deviceName: String
    }
}
