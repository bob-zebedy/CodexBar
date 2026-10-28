import Foundation
import Testing

struct ActivityCommandParserTests {
    @Test(arguments: [
        ("git status", "git"),
        ("python3 - <<'PY'\nprint('pwd; git status')\nPY", "python3"),
        ("NAME=value lark-cli auth status", "lark-cli"),
        ("NAME=value; git status", "git"),
        ("env -u CC -u CXX xcodebuild build", "xcodebuild"),
        ("env -i NAME=value python3 script.py", "python3"),
        ("env --unset=CC -- python3 script.py", "python3"),
        ("env -uCC python3 script.py", "python3"),
        ("xcrun swiftc -version", "swiftc"),
        ("xcrun --sdk macosx --toolchain default swiftc -version", "swiftc"),
        ("xcrun --find swiftc", "xcrun"),
        ("xcrun --show-sdk-path", "xcrun"),
        ("command -v python3", "command"),
        (".venv/bin/python script.py", "python"),
        ("'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' --version", "Google Chrome"),
        ("\"/应用/测试 工具\" --version", "测试 工具"),
        ("/应用/测试\\ 工具 --version", "测试 工具"),
        ("'py'\"thon\"3 script.py", "python3"),
        ("echo 'a;b && c | d'", "echo"),
        ("git status > /tmp/output", "git"),
        ("git -C \"$DIRECTORY\" status", "git"),
        ("# setup\ngit status\n# done", "git"),
        ("/bin/zsh -lc 'python3 script.py'", "python3"),
        ("env -u CC /bin/bash -c 'git status'", "git")
    ])
    func extractsLiteralToolWithoutExecuting(source: String, name: String) {
        #expect(ActivityCommandParser.summarize([source]) == .tool(name))
    }

    @Test(arguments: [
        ("pwd; git status", ["pwd", "git"]), ("pwd\ngit status", ["pwd", "git"]),
        ("pwd && git status", ["pwd", "git"]), ("pwd || git status", ["pwd", "git"]),
        ("git status | wc -l", ["git", "wc"]), ("git status; git diff", ["git"]),
        ("sed -n 1p a; sed -n 2p a; sed -n 3p a", ["sed"]),
        ("/usr/bin/sed -n 1p a; sed -n 2p a", ["sed"]),
        ("git status; git diff; ls", ["git", "ls"]),
        ("git status; ls; git diff; ls -a", ["git", "ls"]),
        ("git status; bash -lc 'git diff; git status; ls'; git log", ["git", "ls"]),
        ("pwd & git status", ["pwd", "git"]),
        ("python3 - <<'PY'\nprint(1)\nPY\ngit status", ["python3", "git"]),
        ("bash -lc 'pwd; git status'", ["pwd", "git"]),
        ("env -u CC zsh -c 'pwd && git status'", ["pwd", "git"])
    ])
    func upToTwoDistinctCommandsPreserveSourceOrder(source: String, names: [String]) {
        #expect(ActivityCommandParser.summarize([source]) == .init(toolNames: names, hasMoreTools: false))
    }

    @Test(arguments: [
        ("git status; ls; pwd", ["git", "ls"]),
        ("git status && ls || pwd", ["git", "ls"]),
        ("git status | wc -l; ls", ["git", "wc"]),
        ("bash -lc 'git status; ls'; pwd", ["git", "ls"]),
        ("git status; bash -lc 'ls; pwd'", ["git", "ls"]),
        ("bash -lc 'git status; ls; pwd'; echo done", ["git", "ls"]),
        ("sed -n 1p a; sed -n 2p a; git status; ls", ["sed", "git"]),
        ("git status; git diff; ls; pwd", ["git", "ls"]),
        ("git status; bash -lc 'git diff; ls; pwd'", ["git", "ls"]),
        ("ls; bash -lc 'git status; ls; pwd'", ["ls", "git"]),
        ("NAME=value; git status; # comment\nls; pwd", ["git", "ls"])
    ])
    func longerSequencesKeepFirstTwoDistinctCommands(source: String, names: [String]) {
        #expect(ActivityCommandParser.summarize([source]) == .init(toolNames: names, hasMoreTools: true))
    }

    @Test(arguments: [
        "", "# comment", "NAME=value", "\"$CMD\" status", "${CMD} status", "$(printf git) status",
        "env \"$CMD\" status", "xcrun \"$CMD\"", "bash -lc \"$SCRIPT\"", "pwd; \"$CMD\" status",
        "git status; ls; pwd; \"$CMD\"", "git status; ls; python3 'unfinished",
        "sed -n 1p a; sed -n 2p a; \"$CMD\"",
        "echo \"$(git status)\"", "cat <(git status)", "cat <<EOF\n$(git status)\nEOF",
        "python3 'unfinished", "echo ${(@s:/:)PATH}", "for x in a b; do git status; done",
        "if test -f marker; then git status; fi", "f() { git status; }; f", "./tool* --version"
    ])
    func uncertainCommandsKeepGenericPresentation(_ source: String) {
        #expect(ActivityCommandParser.summarize([source]) == nil)
    }

    @Test func actionListAndResourceBounds() {
        #expect(ActivityCommandParser.summarize([]) == nil)
        #expect(ActivityCommandParser.summarize(["git status", "pwd"]) == .init(toolNames: ["git", "pwd"], hasMoreTools: false))
        #expect(ActivityCommandParser.summarize(["git status", "ls", "pwd"]) == .init(toolNames: ["git", "ls"], hasMoreTools: true))
        #expect(ActivityCommandParser.summarize(["git status; ls; pwd", "echo done"]) == .init(toolNames: ["git", "ls"], hasMoreTools: true))
        #expect(ActivityCommandParser.summarize(["sed -n 1p a", "sed -n 2p a"]) == .tool("sed"))
        #expect(ActivityCommandParser.summarize(["sed -n 1p a; sed -n 2p a", "git status; git diff"]) == .init(toolNames: ["sed", "git"], hasMoreTools: false))
        #expect(ActivityCommandParser.summarize(["git status", "git diff; ls; pwd"]) == .init(toolNames: ["git", "ls"], hasMoreTools: true))
        #expect(ActivityCommandParser.summarize(["git status", ""]) == nil)
        #expect(ActivityCommandParser.summarize(["git status", "\"$CMD\""]) == nil)
        #expect(ActivityCommandParser.summarize(["git status; ls; pwd", "\"$CMD\""]) == nil)
        #expect(ActivityCommandParser.summarize(Array(repeating: "git status", count: 33)) == nil)
        #expect(ActivityCommandParser.summarize(["echo " + String(repeating: "a", count: 128 * 1024)]) == nil)
        #expect(ActivityCommandParser.summarize([String(repeating: "true;", count: 5000)]) == nil)
        #expect(ActivityCommandParser.summarize(["env env env env git status"]) == nil)
        #expect(ActivityCommandParser.summarize(["git status"]) == .tool("git"))
    }

    @Test func paginatedItemsUseTheSameSummary() throws {
        let page = try TestFixtures.decode(ActivityItemsPage.self, #"""
        {"data":[{"turnId":"turn","item":{"id":"command","type":"commandExecution","status":"completed",
        "commandActions":[{"type":"unknown","command":"pwd; git status"}]}}]}
        """#)
        let item = try #require(page.data.first?.item)
        #expect(item.commandSummary == .init(toolNames: ["pwd", "git"], hasMoreTools: false))
        #expect(item.liveCompletionLabel == ActivityLiveLabel("command-completed", detail: "pwd, git"))
    }

    @Test(arguments: ["null", "123", "{}", "[]", "\"\""])
    func malformedCommandFieldPreservesActivity(_ value: String) throws {
        let item = try TestFixtures.decode(ActivityItem.self, """
        {"id":"cmd","type":"commandExecution","status":"completed", "commandActions":[{"type":"unknown","command":\(value)}]}
        """)
        #expect(item.commandActions?.map(\.type) == ["unknown"])
        #expect(item.commandSummary == nil)
        #expect(item.liveLabel == ActivityLiveLabel("command"))
        #expect(item.liveCompletionLabel == ActivityLiveLabel("command-completed"))
    }
}
