//
//  FolderNode.swift
//  FrameScoop
//
//  文件夹树节点模型：用于侧边栏「逐级展开」的树形结构。
//
//  - 根节点：用户通过 NSOpenPanel 添加的文件夹（对应一个 PhotoFolder / 安全作用域书签）。
//  - 子节点：根目录下的子目录，递归构建，可逐级展开。
//  - id 使用 url.path，保证树重建时同一文件夹的展开/选中状态稳定。
//

import Foundation

struct FolderNode: Identifiable, Hashable {
    /// 节点唯一标识：文件夹路径（跨重建稳定）
    let id: String

    /// 展示名称（根节点可由用户重命名，子节点取目录名）
    var name: String

    /// 文件夹 URL（位于某个根的安全作用域之下，可直接访问）
    var url: URL

    /// 子文件夹；nil 表示叶子（无子目录，不显示展开三角）
    var children: [FolderNode]?

    /// 是否为用户添加的根文件夹
    var isRoot: Bool

    /// 根节点对应的 PhotoFolder.id（用于重命名 / 移除）；子节点为 nil
    var rootID: UUID?
}
