/*
 * SPDX-License-Identifier: GPL-2.0-only
 */

'use strict';
'require dom';
'require rpc';
'require ui';
'require view';

function sortCoreAssets(assets) {
	return assets.slice().sort((a, b) => {
		const alphaA = /-alpha\./.test(a.package_version);
		const alphaB = /-alpha\./.test(b.package_version);
		return Number(alphaA) - Number(alphaB) ||
			b.package_version.localeCompare(a.package_version, undefined, { numeric: true });
	});
}

const callCoreStatus = rpc.declare({
	object: 'luci.sbproxy',
	method: 'core_status',
	expect: { '': {} }
});

const callCoreCheckUpdate = rpc.declare({
	object: 'luci.sbproxy',
	method: 'core_check_update',
	expect: { '': {} }
});

const callCoreUpgrade = rpc.declare({
	object: 'luci.sbproxy',
	method: 'core_upgrade',
	params: [ 'target', 'operation_id' ],
	expect: { '': {} }
});

const callCoreRollback = rpc.declare({
	object: 'luci.sbproxy',
	method: 'core_rollback',
	params: [ 'target', 'operation_id' ],
	expect: { '': {} }
});

const callCoreOperationStatus = rpc.declare({
	object: 'luci.sbproxy',
	method: 'core_operation_status',
	params: [ 'operation_id' ],
	nobatch: true,
	expect: { '': {} }
});

const operationStages = {
	queued: _('Preparing the core operation...'),
	querying: _('Querying published core packages...'),
	downloading: _('Downloading the selected core package...'),
	validating: _('Verifying the package and current configuration...'),
	preparing_recovery: _('Preparing the emergency recovery package...'),
	installing: _('Installing the core package...'),
	restarting: _('Restarting SBProxy; network access may pause briefly...'),
	checking_health: _('Checking core process and listener stability...'),
	restoring: _('Restoring the previous core...')
};

// Never infer success from a version match: reinstall and failed health checks
// can both leave that version installed. Only this job's terminal result counts.
function operationOutcome(result, id) {
	if (result?.code || result?.operation_id !== id)
		return 'unknown';
	if (result.operation_state === 'running')
		return 'running';
	if (result.operation_state === 'succeeded' && result.result_code === 0 &&
		(result.upgraded || result.rolled_back))
		return 'success';
	if (result.operation_state === 'failed')
		return 'failure';
	return 'unknown';
}

const coreErrors = {
	health_snapshot_failed: _('Unable to capture the expected core instances.'),
	already_rolled_back: _('The rollback core is already installed.'),
	candidate_rejected: _('The downloaded package failed metadata, feature, or configuration validation.'),
	checksum_mismatch: _('The downloaded core package failed SHA-256 verification.'),
	current_version_unknown: _('Unable to determine the installed core package version.'),
	download_failed: _('Unable to download the selected core package.'),
	insufficient_storage: _('Not enough persistent storage is available for this core operation.'),
	invalid_target: _('Invalid core package selection.'),
	not_an_upgrade: _('The selected package is not newer than the installed core.'),
	operation_in_progress: _('Another core operation is already in progress.'),
	release_query_failed: _('Unable to query the SBProxy package release.'),
	rollback_checksum_mismatch: _('The rollback package failed SHA-256 verification.'),
	rollback_download_failed: _('Unable to download the current core package for rollback.'),
	rollback_failed: _('Core rollback failed. Check the core manager log immediately.'),
	rollback_metadata_invalid: _('Rollback metadata is incomplete.'),
	rollback_rejected: _('The rollback package failed metadata, feature, or configuration validation.'),
	rollback_source_unavailable: _('The installed core package is no longer in the trusted release, so a safe rollback cannot be prepared.'),
	rollback_unavailable: _('No rollback package is available.'),
	target_unavailable: _('The selected core package is no longer available.'),
	temporary_directory_failed: _('Unable to create a temporary directory.'),
	unsupported_architecture: _('Core updates are not available for this architecture.'),
	upgrade_and_rollback_failed: _('The new core failed and automatic rollback also failed. Check the core manager log immediately.'),
	upgrade_failed_rolled_back: _('The new core failed to install or start; the previous core was restored.')
};

function formatBytes(bytes) {
	const value = Number(bytes) || 0;
	if (value >= 1024 * 1024)
		return _('%s MiB').format((value / 1024 / 1024).toFixed(1));
	if (value >= 1024)
		return _('%s KiB').format((value / 1024).toFixed(1));
	return _('%s B').format(value);
}

function formatKiB(kib) {
	return _('%s MiB').format(((Number(kib) || 0) / 1024).toFixed(1));
}

function formatDate(value) {
	if (!value)
		return '-';
	const date = new Date(value);
	return isNaN(date.getTime()) ? value : date.toLocaleString();
}

function statusText(active, enabled, disabled) {
	return E('strong', { 'style': 'color:%s'.format(active ? 'green' : 'gray') }, [
		active ? enabled : disabled
	]);
}

function resultMessage(result) {
	if (result?.error_code && coreErrors[result.error_code])
		return coreErrors[result.error_code];
	if (result?.error)
		return result.error;
	if (result?.output)
		return result.output;
	return _('Unknown error.');
}

function statusTable(status) {
	const sourceUrl = 'https://github.com/%s/releases'.format(status.repository);
	const required = status.required_tags || [];
	const tags = status.tags || [];
	const featuresReady = required.length > 0 && required.every((tag) => tags.includes(tag));
	const rollback = status.rollback_available ?
		_('%s (saved at %s)').format(status.rollback_package_version || status.rollback_version || '-',
			status.rollback_saved_at || '-') : _('Unavailable');
	const rows = [
		[ _('Core version'), status.version || '-' ],
		[ _('Installed package'), status.package_version || '-' ],
		[ _('Architecture'), [ status.system_arch, status.package_arch ].filter(Boolean).join(' / ') || '-' ],
		[ _('SBProxy service'), statusText(status.service_running, _('Running'), _('Stopped')) ],
		[ _('Build features'), tags.length ? tags.join(', ') : '-' ],
		[ _('Required features'), statusText(featuresReady, _('Complete'), _('Missing')) ],
		[ _('Emergency recovery package'), rollback ],
		[ _('Persistent storage available'), formatKiB(status.overlay_available_kb) ],
		[ _('Temporary storage available'), formatKiB(status.tmp_available_kb) ],
		[ _('Package source'), sourceUrl ? E('a', {
			'href': sourceUrl,
			'target': '_blank',
			'rel': 'noreferrer noopener'
		}, [ status.repository ]) : (status.repository || '-') ]
	];
	const table = E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, [ _('Item') ]),
			E('th', { 'class': 'th' }, [ _('Status') ])
		])
	]);
	cbi_update_table(table, rows);
	return table;
}

function featureTable(status) {
	const compiledTags = status.tags || [];
	const features = [
		[ 'with_acme', _('ACME certificates'), _('Server Settings'), true ],
		[ 'with_clash_api', _('Clash API'), _('URLTest and dashboard'), true ],
		[ 'with_dhcp', _('DHCP DNS transport'), _('Client DNS settings'), true ],
		[ 'with_gvisor', _('gVisor network stack'), _('Client TUN settings'), true ],
		[ 'with_quic', _('QUIC protocols'), _('Hysteria, Hysteria2, TUIC and QUIC DNS'), true ],
		[ 'with_tailscale', _('Tailscale'), _('Tailscale, HTTPS certificates and DERP'), true ],
		[ 'with_utls', _('uTLS fingerprints'), _('Node TLS settings'), true ],
		[ 'with_wireguard', _('WireGuard endpoint'), _('Node Settings'), true ],
		[ null, _('Memory pressure guard'), _('Client advanced settings'), true ]
	];
	const table = E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, [ _('Capability') ]),
			E('th', { 'class': 'th' }, [ _('Compiled') ]),
			E('th', { 'class': 'th' }, [ _('LuCI integration') ])
		])
	]);
	cbi_update_table(table, features.map((feature) => [
		feature[1],
		statusText(feature[0] === null || compiledTags.includes(feature[0]), _('Yes'), _('No')),
		statusText(feature[3], feature[2], feature[2])
	]));
	return table;
}

return view.extend({
	load() {
		return Promise.all([ L.resolveDefault(callCoreStatus(), {
			code: 1,
			manager_supported: false,
			error: _('Unable to read core status.')
		}), L.resolveDefault(callCoreOperationStatus(''), {}) ]);
	},

	showFailure(title, result) {
		ui.showModal(title, [
			E('p', { 'class': 'alert-message error' }, [ resultMessage(result) ]),
			result?.automatic_rollback ?
				E('p', { 'class': 'alert-message warning' }, [
					_('The previous core was restored automatically and SBProxy has been restarted.')
				]) : '',
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'click': ui.hideModal
				}, [ _('Close') ])
			])
		]);
	},

	showSuccess(title, message) {
		ui.showModal(title, [
			E('p', { 'class': 'alert-message success' }, [ message ]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': () => window.location.reload()
				}, [ _('Refresh status') ])
			])
		]);
	},

	showUnconfirmed(title, id) {
		ui.showModal(title, [
			E('p', { 'class': 'alert-message warning' }, [
				_('The operation result cannot be confirmed yet. This does not mean the upgrade failed. Reconnect to the router and check again; do not repeat the installation or power off the router.')
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Close') ]), ' ',
				E('button', { 'class': 'btn cbi-button-action',
					'click': () => this.monitorOperation(title, id)
				}, [ _('Check operation status') ])
			])
		]);
	},

	displayOperation(result) {
		if (!result?.operation_id || !this.operationInfo)
			return;
		this.operationBusy = result.operation_state === 'running';
		this.refreshButtons?.();
		const summary = result.operation_state === 'succeeded' ? _('Completed') :
			result.operation_state === 'failed' ? _('Failed') :
			result.operation_state === 'running' ?
				(operationStages[result.operation_stage] || _('Running')) : _('Result unconfirmed');
		dom.content(this.operationInfo, [
			E('span', {}, [ _('Last core operation: %s — %s').format(result.operation_target || '-', summary) ]), ' ',
			E('button', { 'class': 'btn', 'click': () =>
				this.monitorOperation(_('Core operation progress'), result.operation_id)
			}, [ _('View operation') ])
		]);
	},

	async monitorOperation(title, id) {
		const token = this.monitorToken = (this.monitorToken || 0) + 1;
		const progress = E('p', { 'class': 'spinning' }, [ _('Reading operation status...') ]);
		ui.showModal(title, [
			progress,
			E('p', {}, [ _('The operation runs on the router. Closing this dialog or refreshing the page does not cancel it. Do not power off the router.') ]),
			E('div', { 'class': 'right' }, [ E('button', {
				'class': 'btn', 'click': () => { this.monitorToken++; ui.hideModal(); }
			}, [ _('Close') ]) ])
		]);
		const deadline = Date.now() + 30 * 60 * 1000;
		while (this.monitorToken === token && Date.now() < deadline) {
			let result;
			try {
				result = await callCoreOperationStatus(id);
			} catch (error) {
				if (this.monitorToken !== token) return;
				dom.content(progress, _('Connection interrupted. Waiting for the router to reconnect; the core operation may still be running...'));
				await new Promise((resolve) => setTimeout(resolve, 2000));
				continue;
			}
			if (this.monitorToken !== token) return;
			const outcome = operationOutcome(result, id);
			if (result.operation_id === id) this.displayOperation(result);
			if (outcome === 'success')
				return this.showSuccess(title, (result.rolled_back ?
					_('The sing-box core was rolled back to %s successfully.') :
					_('The sing-box core was upgraded to %s successfully.')).format(result.package_version || '-'));
			if (outcome === 'failure') return this.showFailure(title, result);
			if (outcome === 'unknown') return this.showUnconfirmed(title, id);
			dom.content(progress, operationStages[result.operation_stage] || _('Running'));
			await new Promise((resolve) => setTimeout(resolve, 2000));
		}
		if (this.monitorToken === token) this.showUnconfirmed(title, id);
	},

	async runOperation(title, operation, target) {
		// Generate before the request so even a lost acceptance reply is recoverable.
		const id = Array.from(window.crypto.getRandomValues(new Uint8Array(16)),
			(byte) => byte.toString(16).padStart(2, '0')).join('');
		this.displayOperation({ operation_id: id, operation_target: target,
			operation_state: 'running', operation_stage: 'queued' });
		ui.showModal(title, [ E('p', { 'class': 'spinning' }, [ _('Preparing the core operation...') ]) ]);
		let result;
		try {
			result = await operation(target, id);
		} catch (error) {
			// A transport error says nothing about whether the router accepted the job.
			return this.monitorOperation(title, id);
		}
		if (result?.code) {
			this.operationBusy = false;
			this.refreshButtons?.();
			// Submission was rejected; do not leave a fictitious queued job behind.
			if (this.operationInfo) dom.content(this.operationInfo, []);
			return this.showFailure(title, result);
		}
		return this.monitorOperation(title, id);
	},

	confirmOperation(title, message, operation) {
		ui.showModal(title, [
			E('p', {}, [ message ]),
			E('p', { 'class': 'alert-message warning' }, [
				_('SBProxy will be restarted if it is currently running. Network access may pause briefly.')
			]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'click': ui.hideModal
				}, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': operation
				}, [ _('Continue') ])
			])
		]);
	},

	render(data) {
		const [ status, lastOperation ] = data;
		this.operationBusy = status.busy || lastOperation.operation_state === 'running';
		this.operationInfo = E('div', { 'class': 'cbi-section-descr' });
		let selectedVersion = null;
		let checking = false;
		const updateInfo = E('div', { 'class': 'cbi-section-descr' }, [
			_('Select a published SBProxy core version to upgrade, reinstall or roll back. Historical versions are downloaded from GitHub; no local rollback backup is required.')
		]);
		const selector = E('select', {
			'class': 'cbi-input-select',
			'disabled': '',
			'style': 'min-width:18em'
		}, [ E('option', { 'value': '' }, [ _('Check for updates first') ]) ]);
		const upgradeButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'disabled': '',
			'click': () => {
				const target = selector.value;
				if (!target)
					return;
				const selected = selector.options[selector.selectedIndex]?.textContent || target;
				this.confirmOperation(_('Upgrade sing-box core'),
					_('Upgrade the sing-box core to %s?').format(selected), () =>
						this.runOperation(_('Upgrade sing-box core'), callCoreUpgrade, target));
			}
		}, [ _('Install / reinstall') ]);
		const checkButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'disabled': (status.busy || status.manager_supported === false) ? '' : null,
			'click': ui.createHandlerFn(this, () => {
				checking = true;
				checkButton.disabled = true;
				dom.content(updateInfo, E('span', { 'class': 'spinning' }, [ _('Checking for updates...') ]));
				return L.resolveDefault(callCoreCheckUpdate(), { code: 1 }).then((result) => {
					if (result.code) {
						dom.content(updateInfo, E('span', { 'style': 'color:red' }, [ resultMessage(result) ]));
						return;
					}
					const versions = sortCoreAssets(result.assets || []);
					dom.content(selector, versions.length ? versions.map((asset) => E('option', {
						'value': asset.filename
					}, [ _('%s · %s · %s').format(asset.package_version +
						(/-alpha\./.test(asset.package_version) ? ' (Alpha)' : ''),
						formatBytes(asset.size), formatDate(asset.created_at)) ])) :
						E('option', { 'value': '' }, [ _('No published compatible core versions were found.') ]));
					selector.disabled = !versions.length;
					const selectionChanged = () => {
						selectedVersion = versions.find((asset) => asset.filename === selector.value);
						this.refreshButtons();
					};
					selector.onchange = selectionChanged;
					selectionChanged();
					dom.content(updateInfo, [
						_('Latest stable package: %s').format(result.latest_package_version || '-'),
						' · ', _('Latest alpha package: %s').format(result.latest_alpha_package_version || '-')
					]);
				}).finally(() => {
					checking = false;
					this.refreshButtons();
				});
			})
		}, [ _('Check for updates') ]);
		const rollbackButton = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'disabled': '',
			'click': () => this.confirmOperation(_('Roll back sing-box core'),
				_('Roll back the sing-box core to %s?').format(
					selector.options[selector.selectedIndex]?.textContent || selector.value), () =>
					this.runOperation(_('Roll back sing-box core'), callCoreRollback, selector.value))
		}, [ _('Roll back') ]);
		this.refreshButtons = () => {
			const blocked = this.operationBusy || checking || status.manager_supported === false;
			checkButton.disabled = blocked;
			selector.disabled = blocked || !selectedVersion;
			upgradeButton.disabled = blocked || !selectedVersion || selectedVersion.relation === 'older';
			rollbackButton.disabled = blocked || !selectedVersion || selectedVersion.relation !== 'older';
		};
		this.displayOperation(lastOperation);
		if (lastOperation.operation_state === 'running')
			setTimeout(() => this.monitorOperation(_('Core operation progress'), lastOperation.operation_id), 0);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('Core Management') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Manage the sing-box core used by the client, server and embedded Tailscale services.')
			]),
			E('p', { 'class': 'alert-message warning' }, [
				_('Only sing-box packages built by this project are accepted. Official upstream binaries do not include the SBProxy-specific Tailscale compatibility patches.')
			]),
			status.manager_supported === false ? E('p', { 'class': 'alert-message error' }, [
				_('Core management is not available on this architecture.')
			]) : '',
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Core Status') ]),
				statusTable(status)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Feature Coverage') ]),
				E('div', { 'class': 'cbi-section-descr' }, [
					_('Shows whether each optional core feature is compiled and where SBProxy currently uses it.')
				]),
				featureTable(status)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Upgrade') ]),
				this.operationInfo,
				updateInfo,
				E('div', { 'style': 'display:flex;gap:.5em;align-items:center;flex-wrap:wrap;margin-top:1em' }, [
					checkButton,
					selector,
					upgradeButton,
					rollbackButton
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Rollback') ]),
				E('div', { 'class': 'cbi-section-descr' }, [
					_('Select an older version above to roll back from GitHub. Before switching, an emergency recovery package is downloaded so a failed core can be restored without network access. Incompatible configurations block installation.')
				]),
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
