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

const callPluginCheckUpdate = rpc.declare({
	object: 'luci.sbproxy', method: 'plugin_check_update', expect: { '': {} }
});
const callPluginUpgrade = rpc.declare({
	object: 'luci.sbproxy', method: 'plugin_upgrade',
	params: [ 'target', 'operation_id' ], expect: { '': {} }
});

const callCoreOperationStatus = rpc.declare({
	object: 'luci.sbproxy',
	method: 'core_operation_status',
	params: [ 'operation_id' ],
	nobatch: true,
	expect: { '': {} }
});

const operationStages = {
	queued: _('Preparing the update...'),
	querying: _('Querying published packages...'),
	downloading: _('Downloading packages...'),
	validating: _('Verifying the package and current configuration...'),
	preparing_recovery: _('Preparing the emergency recovery package...'),
	installing: _('Installing packages...'),
	restarting: _('Restarting SBProxy; network access may pause briefly...'),
	checking_health: _('Checking service health...'),
	restoring: _('Restoring the previous version...')
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
	worker_unavailable: _('This firmware cannot start an isolated update worker.'),
	plugin_downgrade: _('Select the current or a newer SBProxy version.'),
	plugin_upgrade_rolled_back: _('The plugin update failed; the previous version and configuration were restored.'),
	plugin_recovery_failed: _('The plugin update and automatic recovery failed. Check the update log.'),
	health_snapshot_failed: _('Unable to capture the expected core instances.'),
	already_rolled_back: _('The rollback core is already installed.'),
	candidate_rejected: _('The downloaded package failed metadata, feature, or configuration validation.'),
	checksum_mismatch: _('The downloaded core package failed SHA-256 verification.'),
	current_version_unknown: _('Unable to determine the installed core package version.'),
	download_failed: _('Unable to download the selected core package.'),
	insufficient_storage: _('Not enough persistent storage is available for this update.'),
	invalid_target: _('Invalid core package selection.'),
	not_an_upgrade: _('The selected package is not newer than the installed core.'),
	operation_in_progress: _('Another update is already in progress.'),
	release_query_failed: _('Unable to query the SBProxy package release.'),
	rollback_checksum_mismatch: _('The rollback package failed SHA-256 verification.'),
	rollback_download_failed: _('Unable to download the current core package for rollback.'),
	rollback_failed: _('Core rollback failed. Check the core manager log immediately.'),
	rollback_metadata_invalid: _('Rollback metadata is incomplete.'),
	rollback_rejected: _('The rollback package failed metadata, feature, or configuration validation.'),
	rollback_source_unavailable: _('The installed package is no longer available in the trusted release, so recovery cannot be prepared.'),
	rollback_unavailable: _('No rollback package is available.'),
	target_unavailable: _('The selected core package is no longer available.'),
	temporary_directory_failed: _('Unable to create a temporary directory.'),
	unsupported_architecture: _('Core updates are not available for this architecture.'),
	upgrade_and_rollback_failed: _('The new core failed and automatic rollback also failed. Check the core manager log immediately.'),
	upgrade_failed_rolled_back: _('The new core failed to install or start; the previous core was restored.')
};

function resultMessage(result) {
	if (result?.error_code && coreErrors[result.error_code])
		return coreErrors[result.error_code];
	if (result?.error)
		return result.error;
	if (result?.output)
		return result.output;
	return _('Unknown error.');
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
					_('The previous version was restored automatically.')
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
			E('span', {}, [ _('Last update: %s — %s').format(result.operation_target || '-', summary) ]), ' ',
			E('button', { 'class': 'btn', 'click': () =>
				this.monitorOperation(_('Update progress'), result.operation_id)
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
				dom.content(progress, _('Connection interrupted. Waiting for the router to reconnect; the update may still be running...'));
				await new Promise((resolve) => setTimeout(resolve, 2000));
				continue;
			}
			if (this.monitorToken !== token) return;
			const outcome = operationOutcome(result, id);
			if (result.operation_id === id) this.displayOperation(result);
			if (outcome === 'success')
				return this.showSuccess(title, (result.component === 'plugin' ?
					_('SBProxy was updated to %s successfully.') : result.rolled_back ?
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
		ui.showModal(title, [ E('p', { 'class': 'spinning' }, [ _('Preparing the update...') ]) ]);
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
		const cards = [];
		this.refreshButtons = () => cards.forEach(card => card.refresh());

		const componentCard = (plugin) => {
			let selected = null, versions = [], checking = false;
			const title = plugin ? _('SBProxy plugin') : _('sing-box core');
			const current = plugin ? status.plugin_version : status.version;
			const info = E('p', { 'class': 'cbi-section-descr' }, [
				plugin ? _('Updates the plugin and its installed Chinese language pack. Your settings are preserved.') :
					_('Choose a stable or Alpha core built with SBProxy compatibility patches.')
			]);
			const selector = E('select', { 'class': 'cbi-input-select', 'disabled': '',
				'style': 'min-width:16em;max-width:100%' }, [
				E('option', { 'value': '' }, [ _('Check for updates first') ])
			]);
			const install = E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': '',
				'click': () => {
					if (!selected) return;
					const rollback = !plugin && selected.relation === 'older';
					this.confirmOperation(title,
						_('Install %s %s?').format(title, selected.package_version), () =>
							this.runOperation(title, plugin ? callPluginUpgrade :
								(rollback ? callCoreRollback : callCoreUpgrade), selected.filename));
				}
			}, [ _('Update') ]);
			const check = E('button', { 'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, async () => {
					checking = true;
					selected = null;
					this.refreshButtons();
					dom.content(info, E('span', { 'class': 'spinning' }, [ _('Checking for updates...') ]));
					try {
						const result = await (plugin ? callPluginCheckUpdate() : callCoreCheckUpdate());
						if (result.code) {
							dom.content(info, E('span', { 'style': 'color:red' }, [ resultMessage(result) ]));
							return;
						}
						versions = plugin ? (result.assets || []).filter(a => a.relation !== 'older')
							.sort((a, b) => b.package_version.localeCompare(a.package_version, undefined, { numeric: true })) :
							sortCoreAssets(result.assets || []);
						dom.content(selector, versions.length ? versions.map(asset => E('option', {
							'value': asset.filename
						}, [ asset.package_version + (/-alpha\./.test(asset.package_version) ? ' (Alpha)' : '') ])) :
							[ E('option', { 'value': '' }, [ _('No available versions') ]) ]);
						selected = (!plugin && /-alpha\./.test(current || '') ?
							versions.find(asset => /-alpha\./.test(asset.package_version)) : null) || versions[0] || null;
						selector.value = selected?.filename || '';
						dom.content(info, plugin ?
							_('Latest version: %s').format(result.latest_package_version || '-') :
							_('Stable: %s · Alpha: %s').format(result.latest_package_version || '-', result.latest_alpha_package_version || '-'));
					} catch (error) {
						dom.content(info, E('span', { 'style': 'color:red' }, [ _('Unable to check for updates. Please try again.') ]));
					} finally {
						checking = false;
						this.refreshButtons();
					}
				})
			}, [ _('Check for updates') ]);
			selector.onchange = () => {
				selected = versions.find(asset => asset.filename === selector.value) || null;
				this.refreshButtons();
			};
			const card = { refresh: () => {
				const blocked = this.operationBusy || checking || status.manager_supported === false;
				check.disabled = blocked;
				selector.disabled = blocked || !selected;
				install.disabled = blocked || !selected;
				dom.content(install, selected?.relation === 'older' ? _('Roll back') :
					(selected?.relation === 'current' ? _('Reinstall') : _('Update')));
			} };
			cards.push(card);
			card.refresh();
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ title ]),
				E('p', {}, [ _('Current version: %s').format(current || '-') ]),
				info,
				E('div', { 'style': 'display:flex;gap:.5em;align-items:center;flex-wrap:wrap' }, [ check, selector, install ])
			]);
		};
		const pluginCard = componentCard(true), coreCard = componentCard(false);
		this.displayOperation(lastOperation);
		if (lastOperation.operation_state === 'running')
			setTimeout(() => this.monitorOperation(_('Update progress'), lastOperation.operation_id), 0);
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('Version Management') ]),
			E('p', { 'class': 'cbi-map-descr' }, [ _('Update SBProxy and its core without updating the router firmware.') ]),
			status.manager_supported === false ? E('p', { 'class': 'alert-message error' }, [
				_('Online updates are not available on this architecture.') ]) : '',
			pluginCard, coreCard, this.operationInfo
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
