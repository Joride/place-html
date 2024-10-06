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
    
    private func placeNonRecursively()
    {
        do
        {
            for anHTMLFileName in try fileManager.contentsOfDirectory(atPath: inputDirectory)
            {
                let htmlFilePath = (inputDirectory as NSString).appendingPathComponent(anHTMLFileName) as String
                
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: htmlFilePath, isDirectory: &isDirectory) &&
                    isDirectory.boolValue
                {
                    continue
                }
                
                // check to see if a js file with the same name (case sensitive!)
                // exists in the outputDir
                let jsFile = jsFilePath(for: anHTMLFileName)
                if fileManager.fileExists(atPath: jsFile)
                {
                    placeHTML(from: htmlFilePath, to: jsFile)
                }
                else
                {
                    print("No corresponding .js file for \(anHTMLFileName). Searched for `\(jsFile)`")
                }
            }
        }
        catch
        {
            print("Aborted: could not list contentsOfDirectory at path: \(inputDirectory)")
            abort()
        }
    }
    
    func jsFilePath(for HTMLFileName: String) -> String
    {
        let fileNameWithoutExtension = (HTMLFileName as NSString).deletingPathExtension as String
        var jsFilePath = (outputDirectory as NSString).appendingPathComponent(fileNameWithoutExtension) as String
        jsFilePath += ".js"
        return jsFilePath
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
    
    private func placeRecursively(inputURL: URL, outputURL: URL)
    {
        walkDirectoryTree(rootDirectory: inputURL) { (fileURL: URL) in
            
            let jsFileURL = jsFileURL(forInputURL: inputURL, 
                                      outputURL: outputURL,
                                      htmlFileURL: fileURL)
            if !fileManager.fileExists(atPath: jsFileURL.path)
            {
                print("Skipping a file! Could not find .js file at `\(jsFileURL.path)` to place html into for \(fileURL)")
            }
            else
            {
                // perform the placement
                placeHTML(from: fileURL.path, to: jsFileURL.path)
                
            }
        }
    }
    
    
    func run() throws
    {
        guard let inputURL = URL(string: inputDirectory)
        else { fatalError("Input path invalid fileURL.") }
        
        guard let outputURL = URL(string: outputDirectory)
        else { fatalError("Output path invalid fileURL.") }
                
        if recursive
        {
            placeRecursively(inputURL: inputURL, outputURL: outputURL)
        }
        else
        {
            placeNonRecursively()
        }
        
        
        if watch
        {
            place_html.fileChangesObserver.delegate = self
            
            var pathsToObserve = [String]()
            if recursive
            {
                walkDirectoryTree(rootDirectory: inputURL)
                {
                    pathsToObserve.append($0.path())
                }
            }
            else
            {
                for anHTMLFileName in try fileManager.contentsOfDirectory(atPath: inputDirectory)
                {
                    let htmlFilePath = (inputDirectory as NSString).appendingPathComponent(anHTMLFileName) as String
                    
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: htmlFilePath, isDirectory: &isDirectory) &&
                        isDirectory.boolValue
                    {
                        continue
                    }
                    pathsToObserve.append(htmlFilePath)
                }
            }
                
            if place_html.fileChangesObserver.start(observingPaths: pathsToObserve)
            {
                // never exit
                RunLoop.main.run()
            }
            else
            {
                print("Unable to start watching. Aborting.")
                abort()
            }
        }
    }
    
    /// The 'meat' of the program: move HTML from one file into a .js file
    private func placeHTML(from htmlPath: String, to jsPath: String)
    {
        do
        {
            let HTMLString = try String(contentsOfFile: htmlPath)
            let jsFileString = try String(contentsOfFile: jsPath)
            let placableHTML = 
"""
\(openingComment)
/*
'\((CommandLine.arguments[0] as NSString).lastPathComponent)' placed the below part by copying the html from `\((htmlPath as NSString).lastPathComponent)`.
\(dateFormatter.string(from: .now))
*/
const template = document.createElement('template');
template.innerHTML = `
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
                // simply prepend html-related code to the file
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
