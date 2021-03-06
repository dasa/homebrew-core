require "language/haskell"

class Ghc < Formula
  include Language::Haskell::Cabal

  desc "Glorious Glasgow Haskell Compilation System"
  homepage "https://haskell.org/ghc/"
  url "https://downloads.haskell.org/~ghc/8.4.3/ghc-8.4.3-src.tar.xz"
  sha256 "ae47afda985830de8811243255aa3744dfb9207cb980af74393298b2b62160d6"

  bottle do
    rebuild 1
    sha256 "d5ee4456af389eac773bf98e1d0b82701a7a16b5050631e2f34dec62a1a06fce" => :mojave
    sha256 "2ca1521c279ecc3042b592ad0ee2a213eaedaf6eb4c71ea1785a03e3c66cdd60" => :high_sierra
    sha256 "3c7aa9670108ad72839c86d8780f9575ebb61dec2f67c739a7edd4d226e1fb44" => :sierra
  end

  head do
    url "https://git.haskell.org/ghc.git", :branch => "ghc-8.4"

    depends_on "autoconf" => :build
    depends_on "automake" => :build
    depends_on "libtool" => :build

    resource "cabal" do
      url "https://hackage.haskell.org/package/cabal-install-2.2.0.0/cabal-install-2.2.0.0.tar.gz"
      sha256 "c856a2dd93c5a7b909597c066b9f9ca27fbda1a502b3f96077b7918c0f64a3d9"
    end
  end

  depends_on "python" => :build if build.bottle?
  depends_on "sphinx-doc" => :build
  depends_on :macos => :lion

  resource "gmp" do
    url "https://ftp.gnu.org/gnu/gmp/gmp-6.1.2.tar.xz"
    mirror "https://gmplib.org/download/gmp/gmp-6.1.2.tar.xz"
    mirror "https://ftpmirror.gnu.org/gmp/gmp-6.1.2.tar.xz"
    sha256 "87b565e89a9a684fe4ebeeddb8399dce2599f9c9049854ca8c0dfbdea0e21912"
  end

  if MacOS.version <= :lion
    fails_with :clang do
      cause <<~EOS
        Fails to bootstrap ghc-cabal. Error is:
          libraries/Cabal/Cabal/Distribution/Compat/Binary/Class.hs:398:14:
              The last statement in a 'do' block must be an expression
                n <- get :: Get Int getMany n
      EOS
    end
  end

  # https://www.haskell.org/ghc/download_ghc_8_0_1#macosx_x86_64
  # "This is a distribution for Mac OS X, 10.7 or later."
  resource "binary" do
    url "https://downloads.haskell.org/~ghc/8.4.3/ghc-8.4.3-x86_64-apple-darwin.tar.xz"
    sha256 "af0b455f6c46b9802b4b48dad996619cfa27cc6e2bf2ce5532387b4a8c00aa64"
  end

  resource "testsuite" do
    url "https://downloads.haskell.org/~ghc/8.4.3/ghc-8.4.3-testsuite.tar.xz"
    sha256 "ff43a015f803005dd9d9248ea9ffa92f9ebe79e146cfd044c3f48e0a7e58a5fc"
  end

  patch :DATA

  def install
    ENV["CC"] = ENV.cc
    ENV["LD"] = "ld"

    # Setting -march=native, which is what --build-from-source does, fails
    # on Skylake (and possibly other architectures as well) with the error
    # "Segmentation fault: 11" for at least the following files:
    #   utils/haddock/dist/build/Haddock/Backends/Hyperlinker/Types.dyn_o
    #   utils/haddock/dist/build/Documentation/Haddock/Types.dyn_o
    #   utils/haddock/dist/build/Haddock/GhcUtils.dyn_o
    #   utils/haddock/dist/build/Paths_haddock.dyn_o
    #   utils/haddock/dist/build/ResponseFile.dyn_o
    # Setting -march=core2 works around the bug.
    # Reported 22 May 2016: https://ghc.haskell.org/trac/ghc/ticket/12100
    # Note that `unless build.bottle?` avoids overriding --bottle-arch=[...].
    ENV["HOMEBREW_OPTFLAGS"] = "-march=#{Hardware.oldest_cpu}" unless build.bottle?

    # Build a static gmp rather than in-tree gmp, otherwise all ghc-compiled
    # executables link to Homebrew's GMP.
    gmp = libexec/"integer-gmp"

    # MPN_PATH: The lowest common denominator asm paths that work on Darwin,
    # corresponding to Yonah and Merom. Obviates --disable-assembly.
    ENV["MPN_PATH"] = "x86_64/fastsse x86_64/core2 x86_64 generic" if build.bottle?

    # GMP *does not* use PIC by default without shared libs  so --with-pic
    # is mandatory or else you'll get "illegal text relocs" errors.
    resource("gmp").stage do
      system "./configure", "--prefix=#{gmp}", "--with-pic", "--disable-shared"
      system "make"
      system "make", "check"
      ENV.deparallelize { system "make", "install" }
    end

    args = ["--with-gmp-includes=#{gmp}/include",
            "--with-gmp-libraries=#{gmp}/lib"]

    # As of Xcode 7.3 (and the corresponding CLT) `nm` is a symlink to `llvm-nm`
    # and the old `nm` is renamed `nm-classic`. Building with the new `nm`, a
    # segfault occurs with the following error:
    #   make[1]: * [compiler/stage2/dll-split.stamp] Segmentation fault: 11
    # Upstream is aware of the issue and is recommending the use of nm-classic
    # until Apple restores POSIX compliance:
    # https://ghc.haskell.org/trac/ghc/ticket/11744
    # https://ghc.haskell.org/trac/ghc/ticket/11823
    # https://mail.haskell.org/pipermail/ghc-devs/2016-April/011862.html
    # LLVM itself has already fixed the bug: llvm-mirror/llvm@ae7cf585
    # rdar://25311883 and rdar://25299678
    if DevelopmentTools.clang_build_version >= 703 && DevelopmentTools.clang_build_version < 800
      args << "--with-nm=#{`xcrun --find nm-classic`.chomp}"
    end

    resource("binary").stage do
      binary = buildpath/"binary"

      system "./configure", "--prefix=#{binary}", *args
      ENV.deparallelize { system "make", "install" }

      ENV.prepend_path "PATH", binary/"bin"
    end

    if build.head?
      resource("cabal").stage do
        system "sh", "bootstrap.sh", "--sandbox"
        (buildpath/"bootstrap-tools/bin").install ".cabal-sandbox/bin/cabal"
      end

      ENV.prepend_path "PATH", buildpath/"bootstrap-tools/bin"

      cabal_sandbox do
        cabal_install "--only-dependencies", "happy", "alex"
        cabal_install "--prefix=#{buildpath}/bootstrap-tools", "happy", "alex"
      end

      system "./boot"
    end

    system "./configure", "--prefix=#{prefix}", *args
    system "make"

    if build.bottle?
      resource("testsuite").stage { buildpath.install Dir["*"] }
      cd "testsuite" do
        system "make", "clean"
        system "make", "CLEANUP=1", "THREADS=#{ENV.make_jobs}", "fast"
      end
    end

    ENV.deparallelize { system "make", "install" }
    Dir.glob(lib/"*/package.conf.d/package.cache") { |f| rm f }
  end

  def post_install
    system "#{bin}/ghc-pkg", "recache"
  end

  test do
    (testpath/"hello.hs").write('main = putStrLn "Hello Homebrew"')
    system "#{bin}/runghc", testpath/"hello.hs"
  end
end

__END__

diff --git a/docs/users_guide/flags.py b/docs/users_guide/flags.py
index cc30b8c066..21c7ae3a16 100644
--- a/docs/users_guide/flags.py
+++ b/docs/users_guide/flags.py
@@ -46,9 +46,11 @@

 from docutils import nodes
 from docutils.parsers.rst import Directive, directives
+import sphinx
 from sphinx import addnodes
 from sphinx.domains.std import GenericObject
 from sphinx.errors import SphinxError
+from distutils.version import LooseVersion
 from utils import build_table_from_list

 ### Settings
@@ -597,14 +599,18 @@ def purge_flags(app, env, docname):
 ### Initialization

 def setup(app):
+    # The override argument to add_directive_to_domain is only supported by >= 1.8
+    sphinx_version = LooseVersion(sphinx.__version__)
+    override_arg = {'override': True} if sphinx_version >= LooseVersion('1.8') else {}

     # Add ghc-flag directive, and override the class with our own
     app.add_object_type('ghc-flag', 'ghc-flag')
-    app.add_directive_to_domain('std', 'ghc-flag', Flag)
+    app.add_directive_to_domain('std', 'ghc-flag', Flag, **override_arg)

     # Add extension directive, and override the class with our own
     app.add_object_type('extension', 'extension')
-    app.add_directive_to_domain('std', 'extension', LanguageExtension)
+    app.add_directive_to_domain('std', 'extension', LanguageExtension,
+                                **override_arg)
     # NB: language-extension would be misinterpreted by sphinx, and produce
     # lang="extensions" XML attributes
