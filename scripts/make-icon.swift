import AppKit
let destination = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
NSColor(calibratedWhite:0.96,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:25,y:25,width:974,height:974),xRadius:205,yRadius:205).fill()
let phone = NSBezierPath(roundedRect:NSRect(x:347,y:181,width:330,height:662),xRadius:62,yRadius:62)
NSColor(calibratedWhite:0.15,alpha:1).setFill(); phone.fill()
NSColor(calibratedWhite:0.985,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:363,y:197,width:298,height:630),xRadius:47,yRadius:47).fill()
NSColor(calibratedWhite:0.15,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:461,y:787,width:102,height:12),xRadius:6,yRadius:6).fill()
NSBezierPath(roundedRect:NSRect(x:461,y:216,width:102,height:8),xRadius:4,yRadius:4).fill()
NSColor(calibratedRed:0.91,green:0.22,blue:0.15,alpha:1).setStroke()
for r in [CGFloat(106),CGFloat(158)] {
 let left=NSBezierPath(); left.appendArc(withCenter:NSPoint(x:360,y:512),radius:r,startAngle:139,endAngle:221,clockwise:false); left.lineWidth=19; left.lineCapStyle = .round; left.stroke()
 let right=NSBezierPath(); right.appendArc(withCenter:NSPoint(x:664,y:512),radius:r,startAngle:319,endAngle:41,clockwise:false); right.lineWidth=19; right.lineCapStyle = .round; right.stroke()
}
NSColor(calibratedRed:0.91,green:0.22,blue:0.15,alpha:1).setFill()
NSBezierPath(ovalIn:NSRect(x:485,y:485,width:54,height:54)).fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination))
