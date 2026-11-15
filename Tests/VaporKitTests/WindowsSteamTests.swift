import XCTest
@testable import VaporKit

final class WindowsSteamTests: XCTestCase {
    func testInitialLoggedOffLineIsNotALogOff() {
        let log = """
        [2026-10-31 19:44:00] [Logged Off, 0, 0] [U:1:0] CCMInterface::SetSteamID( [U:1:0] )
        [2026-10-31 19:44:07] [Logged Off, 4, 0] [U:1:774897551] LogOn() called; not connected yet, scheduling connection.
        [2026-10-31 19:44:14] [Connecting, 4, 0] [U:1:774897551] PingWebSocketCM() failed talking to cm
        """
        XCTAssertEqual(WindowsSteam.parseConnection(log: log), .starting)
    }

    func testLoggedOnWithAccountIDAndCRLF() {
        let log = "[2026-10-31 19:44:18] [Logging On, 4, 7] [U:1:774897551] RecvMsgClientLogOnResponse() : [U:1:774897551] 'OK'\r\n"
            + "[2026-10-31 19:44:18] [Logged On, 4, 7] [U:1:774897551] RecvMsgClientLogOnResponse() : processing complete\r\n"
            + "[2026-10-31 19:44:20] CClientJobGetClientUpdateHosts: cached copy new expiration\r\n"
        XCTAssertEqual(WindowsSteam.parseConnection(log: log), .loggedOn(accountID: 774_897_551))
    }

    func testSessionReplacedIsALogOff() {
        let log = """
        [2026-10-31 20:31:15] [Logged On, 4, 7] [U:1:774897551] RecvMsgClientLogOnResponse() : processing complete
        [2026-10-31 20:31:16] [Logged On, 4, 7] [U:1:774897551] RecvMsgClientLoggedOff('Session Replaced')
        """
        XCTAssertEqual(WindowsSteam.parseConnection(log: log), .loggedOff(reason: "Session Replaced"))
    }

    func testRejectedLogonNeedsLogin() {
        let log = "[2026-10-31 19:44:18] [Logging On, 4, 7] [U:1:774897551] RecvMsgClientLogOnResponse() : [U:1:774897551] 'Access Denied'"
        XCTAssertEqual(WindowsSteam.parseConnection(log: log), .needsLogin)
        for result in ["Invalid Password", "InvalidPassword", "Account Logon Denied", "Expired Login Auth Code"] {
            XCTAssertEqual(WindowsSteam.parseConnection(log: log.replacingOccurrences(of: "Access Denied", with: result)), .needsLogin, result)
        }
    }

    func testShutdownLogOffIsNotOnline() {
        let log = """
        [2026-10-11 09:36:44] [Logged On, 4, 3] [A:1:1939232787:51819] RecvMsgClientLogOnResponse() : processing complete
        [2026-10-11 11:49:47] [Logging Off, 4, 3] [A:1:1939232787:51819] AsyncDisconnect( bDontWaitOnTCPShutdown: true )
        """
        XCTAssertEqual(WindowsSteam.parseConnection(log: log), .starting)
    }

    func testTransientLogonFailureIsRetried() {
        for result in ["Try Another CM", "Service Unavailable", "Timeout"] {
            let log = """
            [2026-10-12 13:54:37] [Logged Off, 4, 0] [A:1:1939232787:51838] ConnectionDisconnected('Disconnected By Remote Host') : 'OK' (205.196.6.132:27018, WebSocket)
            [2026-10-12 13:55:02] [Logging On, 4, 7] [A:1:1939232787:51838] RecvMsgClientLogOnResponse() : [A:1:1939232787:51838] '\(result)'
            """
            XCTAssertEqual(WindowsSteam.parseConnection(log: log), .starting, result)
        }
    }

    func testDisconnectAfterLogonIsReconnecting() {
        let log = """
        [2026-10-12 12:35:28] [Logged On, 4, 7] [A:1:1939232787:51838] RecvMsgClientLogOnResponse() : processing complete
        [2026-10-12 13:54:37] [Logged Off, 4, 0] [A:1:1939232787:51838] ConnectionDisconnected('Disconnected By Remote Host') : 'OK' (205.196.6.132:27018, WebSocket)
        [2026-10-12 13:54:37] [Logged Off, 4, 0] [A:1:1939232787:51838] StartAutoReconnect() will start in 0.0 seconds (attempt 1)
        [2026-10-12 13:54:37] [Logged Off, 4, 0] [A:1:1939232787:51838] Sending SteamServersDisconnected_t because we were logged on
        [2026-10-12 13:54:42] [Connecting, 4, 0] [A:1:1939232787:51838] PingWebSocketCM() (cmp1-lax1.steamserver.net:27018) starting...
        """
        XCTAssertEqual(WindowsSteam.parseConnection(log: log), .starting)
    }

    func testMissedHeartbeatIsReconnecting() {
        let log = """
        [2026-10-12 15:09:51] [Logged On, 4, 15] [A:1:1939232787:51838] RecvMsgClientLogOnResponse() : processing complete
        [2026-10-12 15:27:55] CCMInterface::FailDueToNoHearbeatResponse -- Disconnecting connection and attempting reconnect
        [2026-10-12 15:27:55] [Logged On, 4, 15] [A:1:1939232787:51838] AsyncDisconnect( bDontWaitOnTCPShutdown: true )
        [2026-10-12 15:27:55] CCMInterface::CheckSuspectConnectionWorking() -- Checking if current connection is still good
        """
        XCTAssertEqual(WindowsSteam.parseConnection(log: log), .starting)
    }

    func testLogonAfterReconnectIsOnline() {
        let log = """
        [2026-10-12 13:54:37] [Logged Off, 4, 0] [U:1:774897551] ConnectionDisconnected('Disconnected By Remote Host') : 'OK' (205.196.6.132:27018, WebSocket)
        [2026-10-12 13:54:37] [Logged Off, 4, 0] [U:1:774897551] Sending SteamServersDisconnected_t because we were logged on
        [2026-10-12 15:09:51] [Logging On, 4, 15] [U:1:774897551] RecvMsgClientLogOnResponse() : [U:1:774897551] 'OK'
        [2026-10-12 15:09:51] [Logged On, 4, 15] [U:1:774897551] RecvMsgClientLogOnResponse() : processing complete
        """
        XCTAssertEqual(WindowsSteam.parseConnection(log: log), .loggedOn(accountID: 774_897_551))
    }

    func testLogOffBeatsTheDisconnectThatFollowsIt() {
        let log = """
        [2026-10-31 20:31:15] [Logged On, 4, 7] [U:1:774897551] RecvMsgClientLogOnResponse() : processing complete
        [2026-10-31 20:31:16] [Logged On, 4, 7] [U:1:774897551] RecvMsgClientLoggedOff('Session Replaced')
        [2026-10-31 20:31:16] [Logged Off, 4, 0] [U:1:774897551] ConnectionDisconnected('OK') : 'OK' (162.254.195.75:443, WebSocket)
        """
        XCTAssertEqual(WindowsSteam.parseConnection(log: log), .loggedOff(reason: "Session Replaced"))
    }

    func testClientProcessesExcludeGames() {
        let client = [
            #" C:\Program Files (x86)\Steam\steam.exe -silent -no-cef-sandbox"#,
            #" C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe -lang=en_US"#,
            #" c:\program files (x86)\steam\steamerrorreporter.exe"#,
        ]
        for c in client { XCTAssertTrue(WindowsSteam.isWindowsClientCommand(c), c) }
        let other = [
            #" C:\Program Files (x86)\Steam\steamapps\common\Game\Game.exe -steam"#,
            #" C:\Program Files (x86)\Steam\steamapps\common\steam.exe"#,
            #" C:\windows\system32\explorer.exe"#,
            #" C:\Program Files (x86)\Steam\steamapps\common\Game\Game.exe C:\Program Files (x86)\Steam\steam.exe"#,
        ]
        for c in other { XCTAssertFalse(WindowsSteam.isWindowsClientCommand(c), c) }
    }
}

final class WebHelperCrashTests: XCTestCase {
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    func testQuitSecondsAfterLaunchIsACrash() {
        let log = """
        [2026-11-15 08:33:43] Startup - webhelper launched pid: 316 commandline: "steamwebhelper.exe"
        [2026-11-15 08:33:43] Starting message loop
        [2026-11-15 08:33:46] Quit message loop
        """
        XCTAssertTrue(WindowsSteam.webHelperCrashed(log: log, since: date("2026-11-15 08:33:40")))
    }

    func testNormalShutdownAndOlderSessionsAreNot() {
        let log = """
        [2026-11-14 15:04:02] Startup - webhelper launched pid: 384
        [2026-11-14 21:32:48] Quit message loop
        [2026-11-15 08:29:51] Startup - webhelper launched pid: 300
        [2026-11-15 08:29:55] Quit message loop
        [2026-11-15 08:37:56] Startup - webhelper launched pid: 312
        """
        // A six-hour session that ended normally is not a crash…
        XCTAssertFalse(WindowsSteam.webHelperCrashed(log: String(log.split(separator: "\n").prefix(2).joined(separator: "\n")),
                                                    since: date("2026-11-14 15:04:00")))
        // …the 4-second one that followed is…
        XCTAssertTrue(WindowsSteam.webHelperCrashed(log: log, since: date("2026-11-15 08:29:50")))
        // …and a helper that is still running is not.
        XCTAssertFalse(WindowsSteam.webHelperCrashed(log: log, since: date("2026-11-15 08:37:50")))
    }
}
