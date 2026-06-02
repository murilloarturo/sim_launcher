class Simlauncher < Formula
  desc "macOS menu bar launcher for iPhone, iPad, and Android simulators"
  homepage "https://github.com/murilloarturo/sim_launcher"
  license "MIT"
  head "https://github.com/murilloarturo/sim_launcher.git", branch: "main"

  depends_on xcode: :build
  depends_on macos: :ventura

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"

    app = prefix/"SimLauncher.app"
    (app/"Contents/MacOS").install ".build/release/SimLauncher"
    (app/"Contents").install "Resources/Info.plist"

    (bin/"simlauncher").write <<~SHELL
      #!/bin/bash
      exec "#{app}/Contents/MacOS/SimLauncher" "$@"
    SHELL
  end

  def caveats
    <<~EOS
      Open the menu bar app with:
        open #{opt_prefix}/SimLauncher.app

      Use the CLI helper with:
        simlauncher help
    EOS
  end

  test do
    assert_match "SimLauncher agent commands", shell_output("#{bin}/simlauncher help")
  end
end
