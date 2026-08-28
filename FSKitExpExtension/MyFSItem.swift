//
//  MyFSItem.swift
//  FSKitExp
//
//  Created by Khaos Tian on 3/30/25.
//

import Foundation
import FSKit
import ZipFSCore

final class MyFSItem: FSItem {
    let node: ZipNode
    let name: FSFileName
    var attributes = FSItem.Attributes()
    var xattrs: [FSFileName: Data] = [:]
    
    init(node: ZipNode) {
        self.node = node
        self.name = FSFileName(string: node.name)
        super.init()
        ZipAttributes.apply(to: attributes, node: node)
    }
}
