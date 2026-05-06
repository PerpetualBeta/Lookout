# Lookout — GitHub-attention monitor (PRs awaiting review, etc).
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release. swiftc project, embedded Sparkle,
# dual-ship (.zip + .pkg).

BUNDLE_NAME      := Lookout
BUNDLE_TYPE      := app
PRODUCT_NAME     := Lookout.app
BUNDLE_ID        := cc.jorviksoftware.Lookout
BUILD_SYSTEM     := swiftc

SWIFT_FRAMEWORKS := Cocoa SwiftUI ServiceManagement Security
SWIFT_SOURCES    := main.swift \
                    LookoutKeychain.swift \
                    LookoutGitHub.swift \
                    LookoutCore.swift \
                    LookoutPanel.swift \
                    LookoutSetup.swift

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := Lookout.entitlements

include ../jorvik-release/release.mk
