//
//  FileChangesObserver.swift
//  place-html
//
//  Created by Joride on 30/05/2019.
//

import Foundation
import CoreServices

protocol FileChangesObserverDelegate: AnyObject
{
    func fileChangesObserver(fileChangesObserver: FileChangesObserver,
                             didObserveFileChanges fileChanges: [FileChangesObserver.FileChanges])
}

class FileChangesObserver
{
    weak var delegate: FileChangesObserverDelegate? = nil
    private var eventStreamRef: FSEventStreamRef? = nil
    private var observedPaths: [String]? = nil
    
    func stop()
    {
        if let eventStreamRef = self.eventStreamRef
        {
            FSEventStreamStop(eventStreamRef)
            FSEventStreamInvalidate(eventStreamRef)
            FSEventStreamRelease(eventStreamRef)
            self.eventStreamRef = nil
            self.observedPaths = nil
        }
    }
    
    private func callDelegate(withFileChanges fileChanges: [FileChangesObserver.FileChanges])
    {
        delegate?.fileChangesObserver(fileChangesObserver: self,
                                      didObserveFileChanges: fileChanges)
    }
    
    func start(observingPaths paths: [String]) -> Bool
    {
        if (nil != eventStreamRef) { return false }
        if (0 == paths.count) { return false }
        
        let eventCallback: FSEventStreamCallback = {
            (stream: ConstFSEventStreamRef,
            contextInfo: UnsafeMutableRawPointer?,
            numEvents: Int,
            eventPaths: UnsafeMutableRawPointer,
            eventFlags: UnsafePointer<FSEventStreamEventFlags>,
            eventIds: UnsafePointer<FSEventStreamEventId>) in
            
            guard let paths = unsafeBitCast(eventPaths,
                                            to: NSArray.self) as? [String]
                else { return }
            
            var changesByPath: [String : Set<FileEvent>] = [:]
            for index in 0..<numEvents
            {
                // NOTE: testing these callbacks can be done by creating,
                // modifying, renaming and deleting a text file using Terminal
                // When using Finder, some things are off for unknown reasons.
                
                var changes = Set<FileEvent>()
                
                let anEventFlags = Int(eventFlags[index])
                if kFSEventStreamEventFlagItemCreated ==
                    anEventFlags & kFSEventStreamEventFlagItemCreated
                {
                    changes.insert(.created)
                }
                
                if kFSEventStreamEventFlagItemRemoved ==
                    anEventFlags & kFSEventStreamEventFlagItemRemoved
                { changes.insert(.removed) }
                
                if kFSEventStreamEventFlagItemRenamed ==
                    anEventFlags & kFSEventStreamEventFlagItemRenamed
                { changes.insert(.renamed) }
                
                if kFSEventStreamEventFlagItemModified ==
                    anEventFlags & kFSEventStreamEventFlagItemModified
                { changes.insert(.modified) }
                                
                let eventPath = paths[index]
                if let changesForPath = changesByPath[eventPath]
                {
                    changesByPath[eventPath] = changes.union(changesForPath)
                }
                else
                {
                    changesByPath[eventPath] = changes
                }
            }
            
            var fileChanges = [FileChanges]()
            for (aPath, aChangesSet) in changesByPath
            {
                if aChangesSet.count == 0 { continue }
                
                let newFileChanges = FileChanges(path: aPath,
                                                 changes: aChangesSet)
                fileChanges.append(newFileChanges)
            }
            
            if fileChanges.count > 0
            {
                let fileWatcher: FileChangesObserver = unsafeBitCast(contextInfo,
                                                                     to: FileChangesObserver.self)
                fileWatcher.callDelegate(withFileChanges:fileChanges)
            }
        }
        
        var context = FSEventStreamContext(version: 0,
                                           info: nil,
                                           retain: nil,
                                           release: nil,
                                           copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        if let eventStreamRef =
            FSEventStreamCreate(kCFAllocatorDefault,
                                eventCallback,
                                &context,
                                paths as CFArray,
                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                0,
                                flags)
        {
            self.eventStreamRef = eventStreamRef
            
            FSEventStreamSetDispatchQueue(eventStreamRef, DispatchQueue.main)
        
            observedPaths = paths
            if !FSEventStreamStart(eventStreamRef)
            {
                return false
            }
        }
        else
        {
            observedPaths = nil
            print("❌ FSEventStreamCreate() returned nil")
        }
        return true
    }
    
    enum FileEvent
    {
        case created
        case modified
        case renamed
        case removed
    }
    struct FileChanges: CustomStringConvertible
    {
        let path: String
        let changes: Set<FileEvent>
        
        var description: String
        {
            get
            {
                var description = "\(path) - "
                
                if changes.count > 0
                {
                    //  "{ $0 }" returns the first argument that is passed into
                    // the closure
                    let changesArray = changes.map { $0 }
                    
                    for index in 0 ..< changesArray.count
                    {
                        // first one
                        if 0 == index
                        { description.append("[") }
                        
                        description.append(".\(changesArray[index])")
                        
                        if index < (changesArray.count - 1)
                        { description.append(", ") }
                        
                        // last one
                        if changesArray.count - 1 == index
                        { description.append("]") }
                    }
                }
                else
                {
                    description.append("[]")
                }
                
                return description
            }
        }
    }
}


