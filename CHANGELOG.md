# Changelog

All notable changes to `@meddleware/access-gate-sui` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.0.13] - 2026-11-12

transfer-platform-authority.sh re-derives the multisig address from MULTISIG_PKS, MULTISIG_WEIGHTS and MULTISIG_THRESHOLD and refuses on a mismatch; offline tests for the transfer script and multisig-address.sh.

## [0.0.12] - 2026-11-07

### Changed

- The on-chain guides say "the platform (MeddleWare)" instead of "platform operator" (user-facing documentation).
