//
//  MyFS.swift
//  FSKitExp
//
//  Created by Khaos Tian on 3/30/25.
//

import Foundation
import FSKit
import os
import ZipFSCore

final class MyFS: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    
    private let logger = Logger(subsystem: "FSKitExp", category: "MyFS")
    private var scopedURL: URL?
    
    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        logger.info("probeResource: \(String(describing: resource), privacy: .public)")
        
        do {
            let prefix = try Self.readPrefix(from: resource)
            guard ZipMagic.isZip(prefix: prefix) || SevenZipMagic.isSevenZip(prefix: prefix) else {
                replyHandler(FSProbeResult.notRecognized, nil)
                return
            }
            let name = Self.volumeName(for: resource)
            let containerID = FSContainerIdentifier(
                uuid: ResourceIdentity.uuid(for: Self.resourceKey(resource), namespace: "container")
            )
            replyHandler(FSProbeResult.usable(name: name, containerID: containerID), nil)
        } catch {
            logger.error("probeResource failed: \(error.localizedDescription, privacy: .public)")
            replyHandler(FSProbeResult.notRecognized, nil)
        }
    }
    
    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        logger.info("loadResource: \(String(describing: resource), privacy: .public)")
        
        if options.taskOptions.contains("-f") {
            replyHandler(nil, ZipPOSIX.error(.ENOTSUP))
            return
        }
        
        do {
            let source = try makeSource(from: resource)
            let name = Self.volumeName(for: resource)
            let archiveVolume = try ArchiveOpener.open(source: source, name: name)
            let volume = try MyFSVolume(
                resource: resource,
                archiveVolume: archiveVolume,
                volumeName: name
            )
            containerStatus = .ready
            replyHandler(volume, nil)
        } catch {
            logger.error("loadResource failed: \(error.localizedDescription, privacy: .public)")
            stopScopedAccess()
            replyHandler(nil, ZipPOSIX.map(error))
        }
    }
    
    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        logger.debug("unloadResource: \(resource, privacy: .public)")
        stopScopedAccess()
        reply(nil)
    }
    
    func didFinishLoading() {
        logger.debug("didFinishLoading")
    }
    
    private func makeSource(from resource: FSResource) throws -> ZipSource {
        if #available(macOS 26.0, *), let pathResource = resource as? FSPathURLResource {
            let url = pathResource.url
            if url.startAccessingSecurityScopedResource() {
                scopedURL = url
            }
            return try FileZipSource(url: url)
        }
        if let blockResource = resource as? FSBlockDeviceResource {
            return BlockDeviceZipSource(resource: blockResource)
        }
        throw ZipError.notArchive
    }
    
    private func stopScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
    
    private static func readPrefix(from resource: FSResource) throws -> Data {
        if #available(macOS 26.0, *), let pathResource = resource as? FSPathURLResource {
            let url = pathResource.url
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: 6) ?? Data()
        }
        if let blockResource = resource as? FSBlockDeviceResource {
            let source = BlockDeviceZipSource(resource: blockResource)
            return try source.read(offset: 0, length: 6)
        }
        return Data()
    }
    
    private static func volumeName(for resource: FSResource) -> String {
        if #available(macOS 26.0, *), let pathResource = resource as? FSPathURLResource {
            return pathResource.url.deletingPathExtension().lastPathComponent
        }
        if let blockResource = resource as? FSBlockDeviceResource {
            return blockResource.bsdName
        }
        return "ZipFS"
    }
    
    private static func resourceKey(_ resource: FSResource) -> String {
        if #available(macOS 26.0, *), let pathResource = resource as? FSPathURLResource {
            return pathResource.url.path
        }
        if let blockResource = resource as? FSBlockDeviceResource {
            return blockResource.bsdName
        }
        return String(describing: resource)
    }
}
