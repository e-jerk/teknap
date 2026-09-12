#!/usr/bin/env python3
import pathlib
import sys

version, arm = sys.argv[1], sys.argv[2]
pathlib.Path("Formula").mkdir(exist_ok=True)
pathlib.Path("Formula/teknap.rb").write_text(
    f"""class Teknap < Formula
  desc "OpenNap / Napster client (naps/1 and ircs-u)"
  homepage "https://github.com/e-jerk/teknap"
  version "{version}"
  url "https://github.com/e-jerk/teknap/releases/download/v#{{version}}/teknap-#{{version}}-darwin-arm64.tar.gz"
  sha256 "{arm}"
  license "Unlicense"

  depends_on :macos
  depends_on arch: :arm64
  depends_on "openssl@3"
  depends_on "gnupg"

  def install
    bin.install "teknap"
  end

  test do
    assert_match "TekNap", shell_output("#{{bin}}/teknap -v")
  end
end
"""
)
