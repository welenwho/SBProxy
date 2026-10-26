#!/usr/bin/env python3
"""Versioned SBProxy core releases. Run only in a GitHub Actions checkout.

The package pin is updated AFTER publication. The source fingerprint excludes
generated pins and version fields, so publishing does not trigger a rebuild.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
REPO = 'welenwho/packages'
KEEP_RELEASES = 5
# Published names use the upstream version. Legacy tags may still end in -rN.
VERSION = r'\d+\.\d+\.\d+(?:-alpha\.[1-9]\d*)?'
CORE_TAG = re.compile(r'^sbproxy-core-v(' + VERSION + r')(?:-r([1-9]\d*))?$')
TAGS = ['with_acme', 'with_clash_api', 'with_dhcp', 'with_gvisor',
        'with_quic', 'with_tailscale', 'with_utls', 'with_wireguard']


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def api(path):
    return json.loads(gh('api', path))


def releases():
    pages = json.loads(gh('api', '--paginate', '--slurp',
                         f'repos/{REPO}/releases?per_page=100'))
    return [release for page in pages for release in page]


def fingerprint():
    files = sorted([*ROOT.glob('sing-box/patches/*.patch'),
                    *ROOT.glob('sing-box/tailscale-patches/*.patch'),
                    *ROOT.glob('sing-box/files/*'),
                    ROOT / 'sing-box/Makefile',
                    ROOT / '.github/scripts/core-release.py',
                    ROOT / '.github/scripts/export-core.sh',
                    ROOT / '.github/scripts/build-apk-packages.sh',
                    ROOT / '.github/workflows/Update-Sing-Box.yml',
                    ROOT / '.github/workflows/Build-APK-Packages.yml'])
    digest = hashlib.sha256()
    for path in files:
        content = path.read_bytes()
        if path.name == 'Makefile':
            content = re.sub(rb'^PKG_(UPSTREAM_VERSION|VERSION|RELEASE|HASH):=.*$',
                             b'', content, flags=re.M)
            content = re.sub(rb'^TAILSCALE_MODULE_VERSION:=.*$', b'', content, flags=re.M)
        digest.update(str(path.relative_to(ROOT)).encode() + b'\0' + content + b'\0')
    return digest.hexdigest()


def output(**values):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        for key, value in values.items():
            stream.write(f'{key}={value}\n')


def read_pin():
    path = ROOT / 'sing-box/core-prebuilt.mk'
    return dict(re.findall(r'^(\w+):=(.*)$', path.read_text(), re.M)) if path.exists() else {}


def parse_core_tag(tag):
    match = CORE_TAG.fullmatch(tag or '')
    if not match:
        return None
    version = match[1]
    revision = int(match[2]) if match[2] else None
    return version, revision


def core_tag_key(tag):
    parsed = parse_core_tag(tag)
    if not parsed:
        return None
    version, revision = parsed
    base, _, alpha = version.partition('-alpha.')
    return tuple(int(part) for part in base.split('.')) + (0 if alpha else 1, int(alpha or 0), revision or 0)


def version_channel(version):
    if not re.fullmatch(VERSION, version):
        raise ValueError('Invalid core version')
    return 'alpha' if '-alpha.' in version else 'stable'


def apk_version(version):
    version_channel(version)
    return version.replace('-alpha.', '_alpha')


def select_retained(tags, keep=KEEP_RELEASES, protected=()):
    """Return newest core tags to keep, older tags to delete, and the latest tag."""
    if keep < 1:
        raise ValueError('Retention count must be positive')
    ranked = sorted({tag for tag in tags if core_tag_key(tag)}, key=core_tag_key, reverse=True)
    kept = ranked[:keep]
    kept_set = set(kept)
    for tag in protected:
        if tag in kept_set or tag not in ranked:
            continue
        kept.append(tag)
        kept_set.add(tag)
    stale = [tag for tag in ranked if tag not in kept_set]
    return kept, stale, ranked[0] if ranked else ''


def retain(keep=KEEP_RELEASES):
    keep = int(keep)
    published = [release for release in releases() if not release.get('draft')]
    pin = read_pin().get('CORE_PIN_VERSION', '')
    protected = [f'sbproxy-core-v{pin}'] if core_tag_key(f'sbproxy-core-v{pin}') else []
    kept, stale, newest = [], [], ''
    for channel in ('stable', 'alpha'):
        tags = [release.get('tag_name') or '' for release in published
                if (parsed := parse_core_tag(release.get('tag_name'))) and
                version_channel(parsed[0]) == channel and
                bool(release.get('prerelease')) == (channel == 'alpha')]
        channel_kept, channel_stale, channel_newest = select_retained(tags, keep, protected)
        kept.extend(channel_kept)
        stale.extend(channel_stale)
        if channel == 'stable':
            newest = channel_newest
    repo = os.environ.get('GITHUB_REPOSITORY', REPO)
    for tag in stale:
        subprocess.run(['gh', 'release', 'delete', tag, '--repo', repo,
                        '--cleanup-tag', '--yes'], check=True)
    if newest:
        subprocess.run(['gh', 'release', 'edit', newest, '--repo', repo, '--latest'], check=True)
    print(f'kept={",".join(kept)} stale={",".join(stale)} latest={newest}')


def manifest_of(release):
    asset = next((item for item in release.get('assets', []) if item['name'] == 'core-manifest.json'), None)
    if not asset:
        return None
    return json.loads(subprocess.check_output(
        ['curl', '-fsSL', '--retry', '3', asset['browser_download_url']], text=True))


def public_version(version, revision, manifest=None):
    if manifest and manifest.get('package_version'):
        return manifest['package_version']
    return f'{version}-r{revision}' if revision else version


def resolve(channel='stable'):
    if channel not in ('stable', 'alpha'):
        raise ValueError('Invalid core channel')
    if channel == 'stable':
        upstream = api('repos/SagerNet/sing-box/releases/latest')
    else:
        candidates = [release for release in api('repos/SagerNet/sing-box/releases?per_page=100')
                      if not release.get('draft') and release.get('prerelease') and
                      re.fullmatch(r'v\d+\.\d+\.\d+-alpha\.[1-9]\d*', release.get('tag_name', ''))]
        if not candidates:
            raise ValueError('No upstream alpha release found')
        upstream = max(candidates, key=lambda release: core_tag_key('sbproxy-core-' + release['tag_name']))
    tag = upstream['tag_name']
    if (upstream['draft'] or not tag.startswith('v') or
            version_channel(tag[1:]) != channel or
            bool(upstream['prerelease']) != (channel == 'alpha')):
        raise ValueError('Upstream release does not match the selected channel')
    version = tag[1:]
    source_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    fp = fingerprint()
    pin = read_pin()
    published = []
    for release in releases():
        parsed = parse_core_tag(release.get('tag_name'))
        if (not parsed or parsed[0] != version or release.get('draft') or
                bool(release.get('prerelease')) != (channel == 'alpha')):
            continue
        manifest = manifest_of(release)
        if manifest:
            published.append((parsed[1] or 0, release, manifest))
    # Reconcile a previously published release if committing the pin failed.
    for revision, release, manifest in sorted(published, reverse=True):
        if manifest.get('fingerprint') != fp:
            continue
        identity = public_version(version, revision or None, manifest)
        output(build='false', tag=release['tag_name'], version=version,
               revision=revision or 1, source_sha=source_sha, fingerprint=fp,
               publish_needed=str(channel == 'stable' and (pin.get('CORE_PIN_VERSION') != identity or
                                  pin.get('CORE_FINGERPRINT') != fp)).lower(),
               pin_needed=str(channel == 'stable' and (pin.get('CORE_PIN_VERSION') != identity or
                              pin.get('CORE_FINGERPRINT') != fp)).lower())
        return
    if published:
        # One published name per upstream version. A later build-input change
        # waits for the next upstream release instead of adding -rN.
        revision, release, manifest = sorted(published, reverse=True)[0]
        identity = public_version(version, revision or None, manifest)
        same = manifest.get('fingerprint') == fp
        output(build='false', tag=release['tag_name'], version=version,
               revision=revision or 1, source_sha=source_sha, fingerprint=fp,
               publish_needed='false',
               pin_needed=str(channel == 'stable' and same and (pin.get('CORE_PIN_VERSION') != identity or
                                        pin.get('CORE_FINGERPRINT') != fp)).lower())
        return
    # OpenWrt still needs PKG_RELEASE. It is not part of the published name.
    output(build='true', publish_needed='true', pin_needed=str(channel == 'stable').lower(), version=version, revision=1,
           tag=f'sbproxy-core-v{version}', source_sha=source_sha, fingerprint=fp)


def prepare(version, revision, expected_hash=''):
    if not re.fullmatch(VERSION, version) or not re.fullmatch(r'[1-9]\d*', revision):
        raise ValueError('Invalid build version')
    archive = Path(os.environ['RUNNER_TEMP']) / 'sbproxy-core-source.tar.gz'
    subprocess.run(['curl', '-fsSL', '--retry', '3',
                    f'https://codeload.github.com/SagerNet/sing-box/tar.gz/v{version}',
                    '-o', str(archive)], check=True)
    source_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    if expected_hash and source_hash != expected_hash:
        raise ValueError('Upstream source archive changed since the core build')
    path = ROOT / 'sing-box/Makefile'
    content = path.read_text()
    for key, value in {'PKG_UPSTREAM_VERSION': version, 'PKG_VERSION': apk_version(version),
                       'PKG_RELEASE': revision, 'PKG_HASH': source_hash}.items():
        content = re.sub(r'^' + key + r':=.*$', key + ':=' + value, content, count=1, flags=re.M)
    # Derive the dependency version from this exact upstream tag, not a stale
    # hardcoded version. Patch failure is fatal; never silently drop a patch.
    import tarfile
    with tarfile.open(archive) as tar:
        gomod = tar.extractfile(f'sing-box-{version}/go.mod').read().decode()
    match = re.search(r'github.com/sagernet/tailscale\s+(v[^\s]+)', gomod)
    if not match:
        raise ValueError('Upstream Tailscale dependency not found')
    content = re.sub(r'^TAILSCALE_MODULE_VERSION:=.*$',
                     'TAILSCALE_MODULE_VERSION:=' + match[1], content, flags=re.M)
    path.write_text(content)


def assemble(directory, version, revision, fp, source_sha):
    directory = Path(directory)
    assets = []
    for arch in ('arm64', 'amd64'):
        metadata = json.loads((directory / f'core-{arch}.json').read_text())
        if metadata['version'] != version or metadata['arch'] != arch:
            raise ValueError('Build metadata mismatch')
        for item in metadata['assets']:
            path = directory / item['name']
            if hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
                raise ValueError('Build artifact checksum mismatch')
        assets.append(metadata)
    manifest = dict(schema=1, repository=REPO, profile='sbproxy',
                    version=version, revision=int(revision), package_version=version,
                    channel=version_channel(version), apk_package_version=f'{apk_version(version)}-r{revision}',
                    upstream_tag=f'v{version}', source_sha=source_sha, fingerprint=fp,
                    required_tags=TAGS, patches=['tailscale-route-api', 'tailscale-linux-policy-routing'],
                    builds=assets)
    if assets[0]['source_hash'] != assets[1]['source_hash']:
        raise ValueError('Architectures were built from different upstream archives')
    manifest['source_hash'] = assets[0]['source_hash']
    (directory / 'core-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (directory / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
        for p in sorted(directory.iterdir()) if p.suffix in ('.apk', '.gz', '.json')))


def pin(manifest_path):
    manifest = json.loads(Path(manifest_path).read_text())
    version, revision = manifest['version'], str(manifest['revision'])
    if version_channel(version) != 'stable':
        raise ValueError('Alpha releases must not replace the stable firmware pin')
    if manifest['repository'] != REPO or manifest['profile'] != 'sbproxy':
        raise ValueError('Unexpected core manifest')
    # A concurrent source change must never be pinned to an older artifact.
    if manifest['fingerprint'] != fingerprint():
        raise ValueError('Source changed since build; retry from the current branch')
    prepare(version, revision, manifest['source_hash'])
    entries = {'CORE_PIN_VERSION': public_version(version, int(revision), manifest),
               'CORE_FINGERPRINT': manifest['fingerprint']}
    for build in manifest['builds']:
        tar = next(a for a in build['assets'] if a['name'].endswith('.tar.gz'))
        entries[f'CORE_SHA256_{build["arch"]}'] = tar['sha256']
    if not all(k in entries for k in ('CORE_SHA256_arm64', 'CORE_SHA256_amd64')):
        raise ValueError('Both architectures are required')
    (ROOT / 'sing-box/core-prebuilt.mk').write_text(
        '# Generated after successful immutable core publication. Do not edit hashes.\n' +
        ''.join(f'{key}:={value}\n' for key, value in entries.items()))


def export_metadata(directory, arch, version, apk_arch, binary_sha, build_output, source_hash, tailscale_module):
    directory = Path(directory)
    assets = []
    for path in sorted(directory.iterdir()):
        if path.suffix in ('.apk', '.gz'):
            assets.append(dict(name=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                               size=path.stat().st_size))
    (directory / f'core-{arch}.json').write_text(json.dumps(dict(
        version=version, arch=arch, apk_arch=apk_arch, binary_sha256=binary_sha,
        source_hash=source_hash, tailscale_module=tailscale_module,
        build_output=Path(build_output).read_text(), assets=assets), indent=2) + '\n')


if __name__ == '__main__':
    command, *arguments = sys.argv[1:]
    {'resolve': resolve, 'prepare': prepare, 'assemble': assemble, 'pin': pin,
     'export': export_metadata, 'retain': retain}[command](*arguments)
