class Teknap < Formula
  desc "OpenNap / Napster client (naps/1 and ircs-u)"
  homepage "https://github.com/e-jerk/teknap"
  version "2.0.0"
  license "Unlicense"

  depends_on "openssl@3"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/teknap/releases/download/v#{version}/teknap-#{version}-darwin-arm64.tar.gz"
      sha256 "c5f1a13a5bd9bdfcfbd58e2e1f2edfa34b88cf1e77ad45a80b433953abd21003"
    end
  end

  def install
    bin.install "teknap"
  end

  test do
    assert_match "TekNap", shell_output("#{bin}/teknap -v")
  end
end
