// Not part of any target. Open this file in the gray (debug) Xcode to test.
import SwiftUI

struct ProfileView: View { // begin

    var name: String
    var isOnline: Bool

    var body: some View { // begin
        VStack { // begin
            Text("Hello, \(name)")       // existing comment: left alone
            if isOnline { // begin
                Label("Online", systemImage: "circle.fill")
            } else { // end if isOnline, begin
                Text("Offline")
            } // end else
            let label = "Braces in strings are ignored: { }"
            Button("Refresh") { print(label) }
        } // end VStack
        .padding()
    } // end var body: some View
} // end struct ProfileView: View

func classic()
{ // begin
    for i in 0..<3 { // begin
        print(i)
    } // end for i in 0..<3
} // end func classic()

func test() { // begin
    
} // end func test()

