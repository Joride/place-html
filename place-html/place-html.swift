//
//  main.swift
//  place-html
//
//  Created by Joride on 05/10/2024.
//

import Foundation
import ArgumentParser

private let openingComment = "/*! -- START OF PLACED HTML -- */"
private let closingComment = "/*! -- END OF PLACED HTML -- */"
private let fileManager = FileManager()
private let fileChangesObserver = FileChangesObserver()

private var dateFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en-US")
    dateFormatter.timeZone = TimeZone(identifier: "Europe/Amsterdam")
    dateFormatter.dateFormat = "dd MMM, yyyy 'at' HH:mm:ss '('Z')'"
    return dateFormatter
}()

@main
class PlaceHTML: ParsableCommand
{
    required init(){}
    
    @Flag(name: .shortAndLong,
          help: "Watch for changes to the input directory and place html in the corresponding files of the output directory needed")
    var watch = false
    
    @Flag(name: .shortAndLong,
          help: "When set, recursively operate on all HTML files residing within the root directory (i.e. `input`")
    var recursive = false
    
    @Option(name: [.short, .customLong("input")], 
            help: "The directory containing the html files.")
    var inputDirectory: String
    
    @Option(name: [.short, .customLong("output")],
            help: "The directory containing the js files.")
    var outputDirectory: String
    
    /// recursive
    private func recurseDirectoryTree(rootDirectory rootURL: URL, operation: (URL) -> Void)
    {
        if let enumerator = fileManager.enumerator(at: rootURL,
                                                   includingPropertiesForKeys: [.isRegularFileKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        {
            for case let fileURL as URL in enumerator
            {
                do
                {
                    let fileAttributes = try fileURL.resourceValues(forKeys:[.isRegularFileKey])
                    if fileAttributes.isRegularFile ?? false
                    {
                        operation(fileURL)
                    }
                }
                catch
                {
                    print(error, fileURL)
                }
            }
        }
    }
    
    /// non-recursive, skips directories
    private func enumerateDirectoryTree(rootDirectory rootURL: URL, operation: (URL) -> Void)
    {
        do
        {
            for aFileOrDirectoryName in try fileManager.contentsOfDirectory(atPath: inputDirectory)
            {
                let fullPath = (inputDirectory as NSString).appendingPathComponent(aFileOrDirectoryName) as String
                guard let url = URL(string: fullPath)
                else 
                {
                    print("Programming error: could not get valid path for \(aFileOrDirectoryName)")
                    continue
                }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) &&
                    !isDirectory.boolValue
                {
                    operation(url)
                }
            }
        }
        catch
        {
            print("Aborted: could not list contentsOfDirectory at path: \(inputDirectory)")
            abort()
        }
    }
    
    func run() throws
    {
        guard let inputURL = URL(string: inputDirectory)
        else { fatalError("Input path is an invalid file URL.") }
        
        guard let outputURL = URL(string: outputDirectory)
        else { fatalError("Output path is an invalid file URL.") }
        
        var paths = [String]()
        let operation: (URL)->() = {
            
            let aPath = $0.path
            
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: aPath, isDirectory: &isDirectory) &&
                isDirectory.boolValue
            {
                /// This is a directory
                paths.append(aPath)
            }
            else
            {
                // this is a file, check if it is an HTML file
                if (aPath as NSString).pathExtension != "html" { return }
                
                paths.append(aPath)
                
                // perform placement
                let jsFileURL = self.jsFileURL(forInputURL: inputURL,
                                               outputURL: outputURL,
                                               htmlFileURL: $0)
                if !fileManager.fileExists(atPath: jsFileURL.path)
                {
                    print("Skipping a file! Could not find .js file at `\(jsFileURL.path)` to place html into for \($0)")
                }
                else
                {
                    // perform the placement
                    self.placeHTML(from: $0.path, to: jsFileURL.path)
                }
                
            }
        }
        if recursive
        {
            recurseDirectoryTree(rootDirectory: inputURL,
                                 operation: operation)
        }
        else
        {
            enumerateDirectoryTree(rootDirectory: inputURL,
                                   operation: operation)
        }
        
        if watch
        {
            place_html.fileChangesObserver.delegate = self
            if place_html.fileChangesObserver.start(observingPaths: paths)
            {
                print("Watching '\(inputURL)' for changes.")
                print("!Note: restart this tool when adding new files or folders, as these will not be watched.")
                
                // never exit, keep watching
                RunLoop.main.run()
            }
            else
            {
                print("Unable to start watching. Aborting.")
                abort()
            }
        }
    }
    
    
    private func walkDirectoryTree(rootDirectory rootURL: URL, operation: (URL) -> Void)
    {
        if let enumerator = fileManager.enumerator(at: rootURL,
                                                   includingPropertiesForKeys: [.isRegularFileKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        {
            for case let fileURL as URL in enumerator
            {
                do
                {
                    let fileAttributes = try fileURL.resourceValues(forKeys:[.isRegularFileKey])
                    if fileAttributes.isRegularFile ?? false
                    {
                        operation(fileURL)
                    }
                }
                catch 
                {
                    print(error, fileURL)
                }
            }
        }
    }
    
    private func jsFileURL(forInputURL inputURL: URL, outputURL: URL, htmlFileURL: URL) -> URL
    {
        let inputPathComponents = inputURL.pathComponents
        let filePathComponents = htmlFileURL.pathComponents
        let fileName = (htmlFileURL.lastPathComponent as NSString).deletingPathExtension as String
        
        // `-1`, as the last path component is the fileName
        let nestedPathComponents = filePathComponents[inputPathComponents.count ..< filePathComponents.count - 1]
        
        /// now look for the .js file in the same nested structure in the
        /// output dir
        var jsFileURL = outputURL
        for aNestedPathComponent in nestedPathComponents
        {
            jsFileURL = jsFileURL.appending(path: aNestedPathComponent, directoryHint: .isDirectory)
        }
        jsFileURL = jsFileURL.appending(path: fileName, directoryHint: .notDirectory)
        jsFileURL = jsFileURL.appendingPathExtension("js")
        
        return jsFileURL
    }
    
    /// The 'meat' of the program: move HTML from one file into a .js file
    private func placeHTML(from htmlPath: String, to jsPath: String)
    {
        do
        {
            let jsFileString = try String(contentsOfFile: jsPath)
            let HTMLString = try String(contentsOfFile: htmlPath).trimmingCharacters(in: .whitespacesAndNewlines)
            
            /// find the class name
            let className: String
            if let classDefinitionOpeningRange = jsFileString.range(of: "class "),
                  let classNameClosingRange = jsFileString.range(of: " extends ")
            {
                let subString = jsFileString[classDefinitionOpeningRange.upperBound ..< classNameClosingRange.lowerBound]
                className = String(subString).trimmingCharacters(in: .whitespacesAndNewlines)
                
            }
            else
            {
                print("Unable to find the class name. Putting `<className?>` as placeholder.")
                className = "<className?>"
            }
            
            let placableHTML = 
"""
\(openingComment)
/*
'\((CommandLine.arguments[0] as NSString).lastPathComponent)' placed the below part by copying the html from `\((htmlPath as NSString).lastPathComponent)`.
\(dateFormatter.string(from: .now))
*/
\(className).template = document.createElement('template');
\(className).template.innerHTML = `
\(HTMLString)
`;
\(closingComment)
"""
            
            let updatedjsFileString: String
            if let rangeOfOpeningComment = jsFileString.range(of: openingComment),
               let rangeOfClosingComment = jsFileString.range(of: closingComment)
            {
                let rangeToReplace = rangeOfOpeningComment.lowerBound ..< rangeOfClosingComment.upperBound
                
                // delete the previously entered HTML
                updatedjsFileString = jsFileString.replacingCharacters(in: rangeToReplace,
                                                                       with: placableHTML)
            }
            else
            {
                // simply append html-related code to the file
                updatedjsFileString =
"""
\(jsFileString)

\(placableHTML)
"""
            }
            
            do
            {
                try updatedjsFileString.write(toFile: jsPath,
                                              atomically: true,
                                              encoding: .utf8)
            }
            catch
            {
                print("File skipped! Could not write .js file: \(error)")
            }
        }
        catch
        {
            print("File skipped! Could not read either .html or .js file: \(error)")
        }
    }
}


extension PlaceHTML: FileChangesObserverDelegate
{
    func fileChangesObserver(fileChangesObserver: FileChangesObserver,
                             didObserveFileChanges fileChanges: [FileChangesObserver.FileChanges]) 
    {
        guard let inputURL = URL(string: inputDirectory)
        else { fatalError("Input path invalid fileURL.") }
        
        guard let outputURL = URL(string: outputDirectory)
        else { fatalError("Output path invalid fileURL.") }
        
        for aChange in fileChanges
        {
            
            if aChange.changes.contains(.modified)
            {
                let path = aChange.path
                guard let changedURL = URL(string: aChange.path)
                else 
                {
                    print("! Could not place html for modifications to aChange.path")
                    continue
                }
                            
                let jsFileURL = jsFileURL(forInputURL: inputURL,
                                          outputURL: outputURL,
                                          htmlFileURL: changedURL)
                placeHTML(from: path, to: jsFileURL.path)
                print("\(dateFormatter.string(from: .now)) html from \((changedURL.path as NSString).lastPathComponent) placed into \((jsFileURL.path as NSString).lastPathComponent)")
            }
        }
    }
}
