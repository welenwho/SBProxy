// Run with ucode on OpenWrt; uses only temporary fixture files.
import { writefile, unlink } from 'fs';

const helper = ARGV[0] || '/usr/libexec/sbproxy-core-catalog.uc';
const path = ARGV[1];
if (!match(path || '', /^\/tmp\/sbproxy-core-catalog\.[A-Za-z0-9]+$/))
	die('Pass a fixture path created by mktemp /tmp/sbproxy-core-catalog.XXXXXX');
const tag = 'sbproxy-core-v1.14.0-r2';
const name = 'sing-box-1.14.0-r2-arm64.apk';
const url = `https://github.com/welenwho/packages/releases/download/${tag}/${name}`;
const digest = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const good = { name, browser_download_url: url, digest, size: 128, created_at: '2026-09-08' };
const alphaTag = 'sbproxy-core-v1.15.0-alpha.12';
const alphaName = 'sing-box-1.15.0-alpha.12-arm64.apk';
const alpha = { ...good, name: alphaName,
	browser_download_url: `https://github.com/welenwho/SBProxy/releases/download/${alphaTag}/${alphaName}` };
const cases = [
	[{ tag_name: tag, assets: [good] }, true],
	[{ tag_name: 'sbproxy-core-v1.14.3', assets: [{
		...good,
		name: 'sing-box-1.14.3-arm64.apk',
		browser_download_url: 'https://github.com/welenwho/packages/releases/download/sbproxy-core-v1.14.3/sing-box-1.14.3-arm64.apk'
	}] }, true],
	[{ tag_name: 'sbproxy-core-v1.14.3', assets: [good] }, false],
	[{ tag_name: tag, draft: true, assets: [good] }, false],
	[{ tag_name: tag, prerelease: true, assets: [good] }, false],
	[{ tag_name: alphaTag, prerelease: true, assets: [alpha] }, true],
	[{ tag_name: alphaTag, prerelease: false, assets: [alpha] }, false],
	[{ tag_name: alphaTag, prerelease: true, draft: true, assets: [alpha] }, false],
	[{ tag_name: alphaTag, prerelease: true, assets: [{ ...alpha, digest: null }] }, false],
	[{ tag_name: alphaTag, prerelease: true, assets: [{ ...alpha,
		browser_download_url: replace(alpha.browser_download_url, 'welenwho', 'untrusted') }] }, false],
	[{ tag_name: alphaTag, prerelease: true, assets: [{ ...alpha,
		name: 'sing-box-1.15.0-alpha.13-arm64.apk' }] }, false],
	[{ tag_name: 'apk-packages-arm64', assets: [good] }, false],
	[{ tag_name: tag, assets: [{ ...good, digest: null }] }, false],
	[{ tag_name: tag, assets: [{ ...good, browser_download_url: 'https://example.org/core.apk' }] }, false],
	[{ tag_name: tag, assets: [{ ...good, name: 'sing-box-1.14.0-r2-amd64.apk' }] }, false],
	[{ tag_name: tag, assets: [{ ...good, size: -1 }] }, false],
	// A missing digest on the first asset cannot shift a later asset's hash.
	[{ tag_name: tag, assets: [{ ...good, digest: null }, good] }, true]
];
import { popen } from 'fs';
try {
	for (let c in cases) {
		writefile(path, sprintf('%J', [c[0]]));
		const fd = popen(`ucode ${helper} ${path} arm64`, 'r');
		const result = fd.read('all');
		const code = fd.close();
		if (code || (!!length(result) !== c[1]))
			die('Catalog test failed: ' + sprintf('%J', c[0]));
	}
	print('Core catalog tests passed: architecture, release, URL and digest validation\n');
} catch (e) {
	unlink(path);
	die(e);
}
unlink(path);
