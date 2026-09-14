class Teknap < Formula
  desc "OpenNap / Napster client (naps/1 and ircs-u)"
  homepage "https://github.com/e-jerk/teknap"
  version "2.1.1"
  url "https://github.com/e-jerk/teknap/releases/download/v#{version}/teknap-#{version}-darwin-arm64.tar.gz"
  sha256 "13d47055888a1ec09d792b08be504beb55dcea9392fd10772fd462be5607412d"
  license "Unlicense"

  depends_on :macos
  depends_on arch: :arm64
  depends_on "openssl@3"
  depends_on "gnupg"

  def install
    bin.install "teknap"
  end

  test do
    assert_match "TekNap", shell_output("#{bin}/teknap -v")
  end
end
