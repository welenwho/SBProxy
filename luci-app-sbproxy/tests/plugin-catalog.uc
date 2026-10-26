// Run with ucode on OpenWrt. All files are temporary fixtures.
import { readfile, writefile, unlink, popen } from 'fs';
const helper = ARGV[0];
const path = ARGV[1];
if (!match(path || '', /^\/tmp\/sbproxy-plugin-catalog\.[A-Za-z0-9]+$/)) die('Invalid fixture path');
const tag = 'apk-packages-arm64';
const main = 'luci-app-sbproxy-1.0.1-r39.apk';
const language = 'luci-i18n-sbproxy-zh-cn-1.0.1-r39.apk';
function asset(name) {
	return { name, browser_download_url: `https://github.com/welenwho/SBProxy/releases/download/${tag}/${name}`,
		digest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', size: 128, created_at: '2026-10-26' };
}
const valid = { tag_name: tag, assets: [asset(main), asset(language)] };
const cases = [
	[valid, 2],
	[{ ...valid, tag_name: 'apk-packages-amd64' }, 0],
	[{ ...valid, prerelease: true }, 0],
	[{ ...valid, assets: [asset(main), asset(main)] }, 1],
	[{ ...valid, assets: [{ ...asset(main), digest: '' }] }, 0],
	[{ ...valid, assets: [{ ...asset(main), size: -1 }] }, 0],
	[{ ...valid, assets: [{ ...asset(main), browser_download_url: 'https://example.org/' + main }] }, 0],
	[{ ...valid, assets: [asset('sing-box-1.14.4.apk')] }, 0],
	[{ ...valid, assets: [asset('luci-app-sbproxy-../../bad.apk')] }, 0]
];
for (let c in cases) {
	writefile(path, sprintf('%J', c[0]));
	const fd = popen(`ucode ${helper} ${path} arm64`, 'r');
	const result = trim(fd.read('all'));
	fd.close();
	if ((result ? length(split(result, '\n')) : 0) !== c[1]) die('Catalog mismatch: ' + sprintf('%J', c[0]));
}
unlink(path);
print('Plugin catalog validation passed\n');
