# Changelog

## [2.0.0](https://github.com/nwarila-platform/secure-wazuh/compare/v1.0.0...v2.0.0) (2026-08-31)


### ⚠ BREAKING CHANGES

* **security:** no built-in admin password ([#14](https://github.com/nwarila-platform/secure-wazuh/issues/14))

### Features

* add the out-of-process reaper for stranded AWS resources ([#34](https://github.com/nwarila-platform/secure-wazuh/issues/34)) ([7862f17](https://github.com/nwarila-platform/secure-wazuh/commit/7862f179e7f9d3ad26ce4941b8ce560583617eea))
* adopt golden pins and workflows from pdq-deploy-inventory ([#29](https://github.com/nwarila-platform/secure-wazuh/issues/29)) ([dd863ff](https://github.com/nwarila-platform/secure-wazuh/commit/dd863ffb837b16009764a158e5111cc2586c941a))
* adopt Renovate via the fleet baseline (org ADR-0004) ([#35](https://github.com/nwarila-platform/secure-wazuh/issues/35)) ([49d8f8a](https://github.com/nwarila-platform/secure-wazuh/commit/49d8f8add67ce23c20043caa80268fc1179c2eca))
* prove five connection transports against one AWS topology ([#21](https://github.com/nwarila-platform/secure-wazuh/issues/21)) ([dc42c54](https://github.com/nwarila-platform/secure-wazuh/commit/dc42c54b50e001a521e22663be82b7ff18d18101))


### Bug Fixes

* **iam:** trust the reaper workflow's OIDC identity ([#23](https://github.com/nwarila-platform/secure-wazuh/issues/23)) ([7418f98](https://github.com/nwarila-platform/secure-wazuh/commit/7418f98ee730ec6c29873d7569a46a57508faa15))
* reap with the destroy-only reaper role ([#31](https://github.com/nwarila-platform/secure-wazuh/issues/31)) ([faf7dbf](https://github.com/nwarila-platform/secure-wazuh/commit/faf7dbf162a870eca4814741578f663fb14b5af0))
* **security:** no built-in admin password ([#14](https://github.com/nwarila-platform/secure-wazuh/issues/14)) ([f7c2a22](https://github.com/nwarila-platform/secure-wazuh/commit/f7c2a224cf7cc3f0a3e248b0f4c9e90965ec77e2))


### Documentation

* adopt the development contract in agent guidance ([#36](https://github.com/nwarila-platform/secure-wazuh/issues/36)) ([cb48b30](https://github.com/nwarila-platform/secure-wazuh/commit/cb48b302add27753de0815d8e78fe03f1287cb94))
* ratify guard discipline as audit domain eleven ([#37](https://github.com/nwarila-platform/secure-wazuh/issues/37)) ([47a4cfd](https://github.com/nwarila-platform/secure-wazuh/commit/47a4cfd85cf1f4f2f5e54b12957841a3cc3dd4de))


### Miscellaneous

* read the account id from the org secret ([#33](https://github.com/nwarila-platform/secure-wazuh/issues/33)) ([c4c61b5](https://github.com/nwarila-platform/secure-wazuh/commit/c4c61b5233eb433c15ccd4ab7ec7934c38e3536c))
* read the account id from the org variable ([#32](https://github.com/nwarila-platform/secure-wazuh/issues/32)) ([d186c15](https://github.com/nwarila-platform/secure-wazuh/commit/d186c151bd9de702412f7bcd7c4c7923b525d0e5))
* stop publishing the local agent guidance files ([#38](https://github.com/nwarila-platform/secure-wazuh/issues/38)) ([abb97a5](https://github.com/nwarila-platform/secure-wazuh/commit/abb97a5a2dd707390845b26c9def86a44be55759))

## 1.0.0 (2026-07-22)


### Features

* data-only Terraform inputs for the Proxmox and AWS targets ([cc256d7](https://github.com/nwarila-platform/secure-wazuh/commit/cc256d7d00c2e96a6f5a422ec521e05b77a1c09d))
* STIG/FIPS-hardened Wazuh all-in-one SIEM with Linux and Windows agents ([c6b8592](https://github.com/nwarila-platform/secure-wazuh/commit/c6b85925e59679776651f096798375125f7465d1))


### Documentation

* Diátaxis documentation, ADRs, README, and the layout gate ([7107b2c](https://github.com/nwarila-platform/secure-wazuh/commit/7107b2c55fd0586b007e19ecfb96c4d3a5ee36f0))


### CI/CD

* CI/CD, release automation, security scanning, and the GitOps deploy loop ([1e3d28b](https://github.com/nwarila-platform/secure-wazuh/commit/1e3d28be59021099c947668ab2de61e6ad2b243e))


### Miscellaneous

* repository scaffolding, governance, and the deny-all allowlist ([c9e7a83](https://github.com/nwarila-platform/secure-wazuh/commit/c9e7a837722b9424cc5a0b94c200a5948a147865))

## Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- Release-please will insert new entries above this line -->
