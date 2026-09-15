class Agentbox < Formula
  desc "Run personal Claude Code and Codex sessions in a pinned container runtime"
  homepage "https://github.com/zurfyx/agentbox"
  # Release automation replaces these three identity lines before opening the tap PR.
  url "https://github.com/zurfyx/agentbox/releases/download/v0.1.0/agentbox-0.1.0.tar.gz"
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on "jq"
  depends_on "python@3.14"

  depends_on :macos

  def install
    bin.install "bin/agentbox"
    (libexec/"agentbox").install "libexec/host.sh", "libexec/state.py", "setup-host-bridge.sh"
    bin.install_symlink libexec/"agentbox/setup-host-bridge.sh" => "agentbox-host-bridge"
    pkgshare.install "share/agentbox/VERSION", "share/agentbox/release-manifest.json"

    bash_completion.install "completions/agentbox.bash" => "agentbox"
    zsh_completion.install "completions/_agentbox"
    fish_completion.install "completions/agentbox.fish"

    pkgshare.install "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md"
  end

  test do
    ENV["HOME"] = testpath
    assert_equal version.to_s, (pkgshare/"VERSION").read.strip
    assert_predicate bin/"agentbox-host-bridge", :executable?
    assert_match "usage: agentbox-host-bridge", shell_output("#{bin}/agentbox-host-bridge --help")
    assert_match "agentbox #{version}", shell_output("#{bin}/agentbox --version")
    help = shell_output("#{bin}/agentbox --help")
    assert_match "usage:", help
    assert_match "rollback --accept-vendor-state-risk", help
    refute_path_exists testpath/".agentbox"
  end
end
