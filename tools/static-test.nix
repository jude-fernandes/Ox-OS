# Minimal probe: does -static link work inside the gnu cross stdenv?
let
  flake = builtins.getFlake (toString ./..);
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
in
pkgs.pkgsCross.aarch64-multiplatform.stdenv.mkDerivation {
  name = "static-link-test";
  dontUnpack = true;
  phases = [ "buildPhase" "installPhase" ];
  NIX_LDFLAGS = "-L ${pkgs.pkgsCross.aarch64-multiplatform.glibc}/lib -L ${pkgs.pkgsCross.aarch64-multiplatform.glibc.static}/lib";
  buildPhase = ''
    printf 'int main(void){return 0;}\n' > t.c
    echo "== CC env: [$CC]"
    command -v "$CC" || echo "CC not on PATH"
    command -v aarch64-unknown-linux-gnu-cc || echo "no -cc driver"
    command -v aarch64-linux-gnu-gcc || echo "no short gcc driver"
    echo "== \$CC -static =="
    $CC -static -s t.c -o t1 2>&1 | tail -4 || true
    ls -la t1 2>/dev/null || echo "t1 missing"
    echo "== cc driver -static =="
    aarch64-unknown-linux-gnu-cc -static -s t.c -o t2 2>&1 | tail -4 || true
    ls -la t2 2>/dev/null || echo "t2 missing"
    echo "== short gcc -static =="
    aarch64-linux-gnu-gcc -static -s t.c -o t3 2>&1 | tail -4 || true
    ls -la t3 2>/dev/null || echo "t3 missing"
  '';
  installPhase = ''
    mkdir -p $out
    cp t.c $out/
  '';
}
