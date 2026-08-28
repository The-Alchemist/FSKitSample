//
//  MyFSVolume.swift
//  FSKitExp
//
//  Created by Khaos Tian on 3/30/25.
//

import Foundation
import Darwin
import FSKit
import os
import ZipFSCore

final class MyFSVolume: FSVolume {
    
    private let resource: FSResource
    private let zipVolume: ZipVolume
    private let logger = Logger(subsystem: "FSKitExp", category: "MyFSVolume")
    private var items: [UInt64: MyFSItem] = [:]
    private let rootItem: MyFSItem
    
    init(resource: FSResource, archive: ZipArchive, volumeName: String) throws {
        self.resource = resource
        self.zipVolume = ZipVolume(archive: archive, name: volumeName)
        self.rootItem = MyFSItem(node: zipVolume.root)
        self.items[zipVolume.root.fileID] = rootItem
        
        super.init(
            volumeID: FSVolume.Identifier(
                uuid: ResourceIdentity.uuid(for: volumeName + String(describing: resource), namespace: "volume")
            ),
            volumeName: FSFileName(string: volumeName)
        )
    }
    
    private func item(for node: ZipNode) -> MyFSItem {
        if let existing = items[node.fileID] {
            return existing
        }
        let created = MyFSItem(node: node)
        items[node.fileID] = created
        return created
    }
}

extension MyFSVolume: FSVolume.PathConfOperations {
    
    var maximumLinkCount: Int {
        return 1
    }
    
    var maximumNameLength: Int {
        return 255
    }
    
    var restrictsOwnershipChanges: Bool {
        return true
    }
    
    var truncatesLongNames: Bool {
        return false
    }
    
    var maximumXattrSize: Int {
        return 0
    }
    
    var maximumFileSize: UInt64 {
        return UInt64.max
    }
}

extension MyFSVolume: FSVolume.Operations {
    
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        logger.debug("supportedVolumeCapabilities")
        
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHardLinks = false
        capabilities.supportsSymbolicLinks = false
        capabilities.supportsPersistentObjectIDs = true
        capabilities.doesNotSupportVolumeSizes = true
        capabilities.supportsHiddenFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.caseFormat = .sensitive
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        logger.debug("volumeStatistics")

        let result = FSStatFSResult(fileSystemTypeName: "MyFS")
        let total = max(zipVolume.archive.totalUncompressedSize, 1)
        result.blockSize = 4096
        result.ioSize = 4096
        result.totalBlocks = (total + 4095) / 4096
        result.availableBlocks = 0
        result.freeBlocks = 0
        result.totalFiles = UInt64(zipVolume.archive.entries.count)
        result.freeFiles = 0
        return result
    }

    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions {
        get { .readOnly }
        set { }
    }
    
    func activate(options: FSTaskOptions) async throws -> FSItem {
        logger.debug("activate")
        return rootItem
    }
    
    func deactivate(options: FSDeactivateOptions = []) async throws {
        logger.debug("deactivate")
    }
    
    func mount(options: FSTaskOptions) async throws {
        logger.debug("mount")
    }
    
    func unmount() async {
        logger.debug("unmount")
    }
    
    func synchronize(flags: FSSyncFlags) async throws {
        logger.debug("synchronize")
    }
    
    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let item = item as? MyFSItem else {
            throw ZipPOSIX.error(.EIO)
        }
        logger.debug("getItemAttributes: \(item.name)")
        return item.attributes
    }
    
    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        logger.debug("setItemAttributes: \(item)")
        throw ZipPOSIX.error(.EROFS)
    }
    
    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        logger.debug("lookupName: \(String(describing: name.string)), \(directory)")
        
        guard let directory = directory as? MyFSItem else {
            throw ZipPOSIX.error(.ENOENT)
        }
        guard let nameString = name.string else {
            throw ZipPOSIX.error(.ENOENT)
        }
        
        do {
            let node = try zipVolume.lookup(name: nameString, in: directory.node)
            let item = item(for: node)
            return (item, name)
        } catch {
            throw ZipPOSIX.map(error)
        }
    }
    
    func reclaimItem(_ item: FSItem) async throws {
        logger.debug("reclaimItem: \(item)")
    }
    
    func readSymbolicLink(
        _ item: FSItem
    ) async throws -> FSFileName {
        throw ZipPOSIX.error(.EINVAL)
    }
    
    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        throw ZipPOSIX.error(.EROFS)
    }
    
    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        throw ZipPOSIX.error(.EROFS)
    }
    
    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> FSFileName {
        throw ZipPOSIX.error(.EROFS)
    }
    
    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem
    ) async throws {
        throw ZipPOSIX.error(.EROFS)
    }
    
    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        throw ZipPOSIX.error(.EROFS)
    }
    
    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        logger.debug("enumerateDirectory: \(directory)")

        guard let directory = directory as? MyFSItem else {
            throw ZipPOSIX.error(.ENOTDIR)
        }
        
        do {
        let entries = try zipVolume.enumerate(directory.node, startingAt: UInt64(cookie.rawValue))
            for entry in entries {
                let item = item(for: entry.node)
                let packed = packer.packEntry(
                    name: item.name,
                    itemType: item.attributes.type,
                    itemID: item.attributes.fileID,
                    nextCookie: FSDirectoryCookie(entry.nextCookie),
                    attributes: attributes != nil ? item.attributes : nil
                )
                if !packed {
                    break
                }
            }
        } catch {
            throw ZipPOSIX.map(error)
        }

        return FSDirectoryVerifier(0)
    }
}

extension MyFSVolume: FSVolume.OpenCloseOperations {
    
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        if let item = item as? MyFSItem {
            logger.debug("open: \(item.name)")
        }
    }
    
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        if let item = item as? MyFSItem {
            logger.debug("close: \(item.name)")
        }
    }
}

extension MyFSVolume: FSVolume.XattrOperations {

    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        if let item = item as? MyFSItem {
            return item.xattrs[name] ?? Data()
        }
        return Data()
    }
    
    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy) async throws {
        throw ZipPOSIX.error(.EROFS)
    }
    
    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        if let item = item as? MyFSItem {
            return Array(item.xattrs.keys)
        }
        return []
    }
}

extension MyFSVolume: FSVolume.ReadWriteOperations {

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        guard let item = item as? MyFSItem else {
            throw ZipPOSIX.error(.EIO)
        }
        
        do {
            let data = try zipVolume.read(item.node, offset: UInt64(max(offset, 0)), length: min(length, buffer.length))
            let count = min(buffer.length, data.count)
            _ = buffer.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    memcpy(dst.baseAddress, src.baseAddress, count)
                }
            }
            return count
        } catch {
            throw ZipPOSIX.map(error)
        }
    }
    
    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        throw ZipPOSIX.error(.EROFS)
    }
}
