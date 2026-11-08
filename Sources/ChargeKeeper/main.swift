import SwiftUI

#if CK_TEST_COMMANDS
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--ctl" {
    TestCommands.run(Array(CommandLine.arguments.dropFirst(2)))
}
#endif

ChargeKeeperApp.main()
