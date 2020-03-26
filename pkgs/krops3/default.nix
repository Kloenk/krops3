let
  lib = import ../../lib;
in

{ writeScript
, writeText
, substituteAll
, bash
, openssh
, rsync
, pass
}:

rec {

  nixos-rebuild = substituteAll {
    name = "nixos-rebuild";
    src = <nixpkgs/nixos/modules/installer/tools/nixos-rebuild.sh>;
    dir = "bin";
    isExecutable = true;
    postInstall = ''
      sed -i $target \
      -e "s/nix-copy-closure /&-s /g"
    '';
  };

  getSources = {
    target
  }: let
    target' = lib.mkTarget target;
  in ''
    if [ -z $NIXPKGS_SRC ]; then
      set +e
      nixpkgs_version=$(${openssh}/bin/ssh $NIX_SSHOPTS -p ${target'.port} ${target'.host} "cat /etc/src/nixpkgs.sha256")
      if [ -z $nixpkgs_version ]; then
        echo "could not fetch nixpkgs revision"
        exit 1
      fi
      set -e
      nixpkgs_src=$HOME/.cache/krops3/src/''${nixpkgs_version}/
      if [ ! -d $NIXPKGS_SRC ]; then
        mkdir -p $NIXPKGS_SRC
        ${openssh}/bin/ssh $NIX_SSHOPTS -p ${target'.port} ${target'.host} "cat /etc/src/nixpkgs.tar.gz" | tar xf - -C $NIXPKGS_SRC
      fi
    fi  
  '';

  populatePass = {
    target,
    name,
    srcDir ? "$HOME/.password-store/",
    destDir ? "/var/src/secrets/"
  }: let
    target' = lib.mkTarget target;
  in ''
    tmpdir="$(mktemp -p /dev/shm -d --suffix "krops3-populate")"
    trap "rm -rf ''${tmpdir};" EXIT

    mkdir -p "$tmpdir/${name}"
    find "${srcDir}/${name}" -type f |
    while read -r gpg_path; do
      rel_name=''${gpg_path#${srcDir}}
      rel_name=''${rel_name%.gpg}
      mkdir -p "$(dirname "$tmpdir/$rel_name")"
      PASSWORD_STORE_DIR=${srcDir} ${pass}/bin/pass "$rel_name" > "$tmpdir/$rel_name"
    done

    if [ "${name}" != "$(hostname)" ]; then
      ${rsync}/bin/rsync -avP "$tmpdir/${name}/" -e "ssh -p${target'.port}" --rsync-path="sudo rsync" "${target'.host}:${destDir}" >/dev/null
    else
      sudo ${rsync}/bin/rsync -avP "$tmpdir/${name}/" "${destDir}" >/dev/null
    fi
  '';

  writeDeploy = name: {
    buildTarget ? "localhost:22",
    fast ? false,
    sudo ? false,
    populate ? true,
    useHostNixpkgs ? false,
    extraSources ? [],
    passSrcDir ? "$HOME/.password-store/",
    passDestDir ? "/var/src/secrets",
    configuration,
    target
  }: let
    target' = lib.mkTarget target;
    buildTarget' = lib.mkTarget buildTarget;
    nixos-config = writeText "nixos-config.${name}" ''
      { ... }:

      {
        imports = [
          ${toString configuration}
          ${lib.concatStringsSep "\n" (map (source: toString source)extraSources)}
        ];
      }
    '';
  in writeScript "krops-${name}" ''
    #!${bash}/bin/bash
    mode=$1
    shift
    args=$@

    [ "$mode" == "" ] && mode="switch"

    set -e
    ${lib.optionalString useHostNixpkgs (getSources { target = target'; })}

    ${populatePass { inherit name target; srcDir = passSrcDir; destDir = passDestDir; }} # TODO: non sudo foo

    if [ "${name}" != "$(hostname)" ]; then
      echo "working remote on \"${name}:${target'.port}\""
      args="$args --target-host ${target'.host}"
      export NIX_SSHOPTS="$NIX_SSHOPTS -p${target'.port}"
    else
      echo "working on localhost"
    fi

    ${lib.optionalString sudo "args=\"$args --use-remote-sudo\""}

    ${nixos-rebuild}/bin/nixos-rebuild $mode \
      -I secrets="$tmpdir" \
      -I nixos-config="${nixos-config}" \
      ${lib.optionalString useHostNixpkgs "-I nixpkgs=\"$NIXPKGS_SRC\""} \
      --build-host ${buildTarget'.host} \
      $args
  '';
}
