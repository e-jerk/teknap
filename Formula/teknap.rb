class Teknap < Formula
  desc "OpenNap / Napster client (naps/1 and ircs-u)"
  homepage "https://github.com/e-jerk/teknap"
  version "VERSION_PLACEHOLDER"
  license "Unlicense"

  depends_on "openssl@3"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/teknap/releases/download/v#{version}/teknap-#{version}-darwin-arm64.tar.gz"
      sha256 "SHA256_DARWIN_ARM64"
    end
    on_intel do
      url "https://github.com/e-jerk/teknap/releases/download/v#{version}/teknap-#{version}-darwin-amd64.tar.gz"
      sha256 "SHA256_DARWIN_AMD64"
    end
  end

  def install
    bin.install "teknap"
  end

  test do
    assert_match "TekNap", shell_output("#{bin}/teknap -v")
  end
end
