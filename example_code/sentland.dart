// Landscape generator for The Sentinel (aka The Sentry)
//
// Generates the landscapes and placed object from the original game.
//
// Original algorithim converted by Simon Owen https://github.com/simonowen/sentland

import 'dart:math';
import 'dart:io';
import 'dart:typed_data';
import 'package:format/format.dart';
import 'package:intl/intl.dart';

enum ObjType {
  NONE,
  ROBOT,
  SENTRY,
  TREE,
  BOULDER,
  MEANIE,
  SENTINEL,
  PEDESTAL,
}

class GameObject {
  ObjType type;
  int x, y, z;
  int? rot;
  int? step;
  int? timer;

  GameObject(this.type, this.x, this.y, this.z);

  // Generate string representation of object
  @override
  String toString() {
    String name = type.toString().split('.').last;
    String rotdeg = rot != null ? "${(rot! * 360 ~/ 256).toString().padLeft(3, '0')}°" : "";
    String rotdir = step == null ? "" : (step! < 0 ? " ↺" : " ↻");

    String result = "$name: x=${x.toRadixString(16).toUpperCase()} y=${y.toRadixString(16).toUpperCase()} z=${z.toRadixString(16).toUpperCase()}";
    if (rot != null) result += " rot=${rot!.toRadixString(16).toUpperCase()} ($rotdeg$rotdir)";
    if (timer != null) result += " next=${timer!.toRadixString(16).toUpperCase()}";
    
    return result;
  }
}


class RNG {
  BigInt _ull = BigInt.from(1 << 16);
  int _usage = 0;

  RNG(int seed) {
    _ull |= BigInt.from(seed);
  }

  /// The RNG used is a 40-bit linear feedback shift register. Bits 33 and 20 are
  /// XORed and fed back into bit 0 after each shift. The top 8 bits form the new
  /// random value after 8 shift iterations.
  int next() {
    for (int i = 0; i < 8; i++) {
      _ull = _ull << 1;
      _ull = _ull | (((_ull >> 20) ^ (_ull >> 33)) & BigInt.from(1));
    }
    _usage++;
    var result = (_ull >> 32) & BigInt.from(0xFF);
    return result.toInt();
  }

  int range(int min, int max) {
    return min + (next() % (max - min + 1));
  }

  /// Random number in range 0 to 0x16
  int range_00_16() {
    var r = next();
    print(r);
    return (r & 7) + ((r >> 3) & 0xF);
  }
}


class MapProcessor {

  /// Return x or z slice from the map, wrapped around at the edges
  static List<int> wrappedSlice(List<List<int>> mapArr, int r, {int entries=0x23, String axis="z"})
  {
    List<int> row = [];
    for (var i=0;i<entries;i++)
    {
    if (axis == "z")
        row.add(mapArr[r][i & 0x1F]);
    else
        row.add(mapArr[i & 0x1F][r]);
    }
    return row;
  }

  /// Smooth a map slice by averaging neighbouring groups of values
  static List<int> smoothSlice(List<int> arr) {
    int groupSize = arr.length - 0x1F;
    return [
      for (int x = 0; x < arr.length - groupSize + 1; x++)
        arr.sublist(x, x + groupSize).reduce((a, b) => a + b) ~/ groupSize
    ];
  }

  /// Smooth the map by averaging groups across the given axis
  static List<List<int>> smoothMap(List<List<int>> mapArr, String axis) {
    if (axis == "z") {
      return [
        for (int z = 0; z < 0x20; z++) smoothSlice(wrappedSlice(mapArr, z, axis:"z"))
      ];
    }
    List<List<int>> newMapArr = List.generate(0x20, (_) => List.filled(0x20, 0));
    for (int x = 0; x < 0x20; x++) {
      List<int> smoothedColumn = smoothSlice(wrappedSlice(mapArr, x, axis:"x"));
      for (int z = 0; z < 0x20; z++) {
        newMapArr[z][x] = smoothedColumn[z];
      }
    }
    return newMapArr;
  }

  
  /// Smooth 3 map vertices, returning a new central vertex height
  static int despikeMidval(List<int> arr)
  {
    if (arr[1] == arr[2]) {
        return arr[1];
    }
    else if (arr[1] > arr[2]) {
        if (arr[1] <= arr[0]) {
            return arr[1];
        }
        else if (arr[0] < arr[2]) {
            return arr[2];
        }
        else {
            return arr[0];
        }
    }
    else if (arr[1] >= arr[0]) {
        return arr[1];
    }
    else if (arr[2] < arr[0]) {
        return arr[2];
    }
    else {
        return arr[0];
    }
  }

  /// Smooth a slice by flattening single vertex peaks and troughs
  static List<int> despikeSlice(List<int> arr)
  {
    var arr_copy = [...arr];
    for (var x=0x20-1;x>=0;x--)
    {
        arr_copy[x + 1] = despikeMidval([arr_copy[x], arr_copy[x+1], arr_copy[x+2]]);
    }
    return arr_copy.take(0x20).toList();
  }

  /// De-spike the map in slices across the given axis
  static List<List<int>> despikeMap(List<List<int>> mapArr, String axis)
  {
    if (axis == "z")
    {
      return [
        for (int z = 0; z < 0x20; z++) despikeSlice(wrappedSlice(mapArr, z, axis:"z"))
      ];
    }

    List<List<int>> newMapArr = List.generate(0x20, (_) => List.filled(0x20, 0));
    for (int x = 0; x < 0x20; x++) {
      List<int> despikedColumn = despikeSlice(wrappedSlice(mapArr, x, axis:"x"));
      for (int z = 0; z < 0x20; z++) {
        newMapArr[z][x] = despikedColumn[z];
      }
    }
    return newMapArr;
  }


  // Scale and offset values to generate vertex heights
  static int scaleAndOffset(int val, {int scale=0x18})
  {
    double mag = val - 0x80;  // 7-bit signed range
    mag = mag * scale / 256;  // scale and use upper 8 bits
    mag = max(mag + 6, 0);  // centre at 6 and limit minimum
    mag = min(mag + 1, 11);  // raise by 1 and limit maximum
    return mag.toInt();
  }

/// Determine tile shape code from 4 vertex heights
static int tileShape(int fl, int bl, int br, int fr)
{
  int shape;
    if (fl == fr) {
        if (fl == bl) {
            if (fl == br)     shape = 0;   
            else if (fl < br) shape = 0xA;
            else              shape = 0x3;
        }
        else if (br == bl) {
            if (br < fr)      shape = 0x1;
            else              shape = 0x9;
        }
        else if (br == fr) {
            if (br < bl)      shape = 0x6;
            else              shape = 0xF;
        }
        else {                shape = 0xC;
        }
    }
    else if (fl == bl) {
        if (br == fr) {
            if (br < bl) shape = 0x5;
            else         shape = 0xD;
        }
        else if (br == bl) {
            if (br < fr) shape = 0xE;
            else         shape = 0x7;
        }
        else {           shape = 0x4;
        }
    }
    else if (br == fr) {
        if (br == bl) {
            if (br < fl) shape = 0xB;
            else         shape = 0x2;
        }
        else {
            shape = 0x4;
        }
    }
    else {               shape = 0xC;
    }

    return shape;
  }

  /// Add tile shape code to upper 4 bits of each tile
  static List<List<int>> addTileShapes(List<List<int>> mapArr)
  {
    var newMapArr = [...mapArr];
    for (var z = 0x1F-1; z>=0; z--) {
        for (var x = 0x1F-1; x>=0; x--) {
            var fl = mapArr[z + 0][x + 0] & 0xF;
            var bl = mapArr[z + 1][x + 0] & 0xF;
            var br = mapArr[z + 1][x + 1] & 0xF;
            var fr = mapArr[z + 0][x + 1] & 0xF;
            var shape = tileShape(fl, bl, br, fr);
            newMapArr[z][x] = (shape << 4) | (mapArr[z][x] & 0xF);
        }
    }
    return newMapArr;
  }


  /// Swap upper and lower 4 bits in each map byte
  static List<List<int>> swapNibbles(List<List<int>> mapArr)
  {    
    for (int x = 0; x < 0x20; x++) {
      for (int z = 0; z < 0x20; z++) 
      {
        var orig = mapArr[z][x];
        mapArr[z][x] = (orig & 0xF) << 4 | (orig >> 4); 
      }
    }
    return mapArr;
  }
  
}

class CoordinateUtils {
  // Convert x and z coordinates to linear offset into game map data
  static int getOffset(int x, int z) {
    return ((x & 3) << 8) | ((x & 0x1C) << 3) | z;
  }

  // Convert linear game map data offset to x and z coordinates
  static Map<String, int> getXZ(int offset) {
    int x = ((offset & 0x300) >> 8) | ((offset & 0xE0) >> 3);
    int z = offset & 0x1F;
    return {'x': x, 'z': z};
  }
  static int getX(int offset) {
    int x = ((offset & 0x300) >> 8) | ((offset & 0xE0) >> 3);
    return x;
  }
  static int getZ(int offset) {
    int z = offset & 0x1F;
    return z;
  }

  // Return map entry at given original game map offset
  static int AtOffset(List<List<int>> mapArr, int offset)
  {
    return mapArr[getZ(offset)][getX(offset)];
  }
}

class MapEncoding {
  /// Return map code at given map location
  static int ShapeAt(int x, int z, List<List<int>> mapArr)
  {
    return mapArr[z][x] & 0xF;
  }

  /// Return map height at given location
  static int HeightAt(int x, int z, List<List<int>> mapArr)
  {
    return mapArr[z][x] >> 4;
  }

  /// Return true if the map location is a flat tile
  static bool IsFlat(int x, int z, List<List<int>> mapArr)
  {
    return ShapeAt(x,z,mapArr) == 0;
  }

}

class LandscapeGenerator {

  /// Generate landscape data for given landscape number
  static List<List<int>> generateLandscape(int landscape_bcd) {

    RNG rng = RNG(landscape_bcd);

    // Read 81 values to warm the RNG.
    for (var r=0;r<0x51;r++) {
      rng.next();
    }

    // Random height scaling (but fixed value for landscape 0000!).
    var heightScale = (landscape_bcd > 0) ? rng.range_00_16() + 0x0E : 0x18;

    // Fill the map with random values (z from back to front, x from right to left).
    List<List<int>> mapArr = [];
    for (var x=0;x<32;x++)
    {
      List<int> row = [];
      for (var z=0;z<32;z++)
      {
        row.insert(0,rng.next());
      }
      mapArr.insert(0,row);
    }
 
    verify(mapArr, landscape_bcd, "random");

    // 2 passes of smoothing, each across z-axis then x-axis.
    for (var i=0;i<2;i++)
    {
        mapArr = MapProcessor.smoothMap(mapArr, "z");
        mapArr = MapProcessor.smoothMap(mapArr, "x");
    }
    verify(mapArr, landscape_bcd, "smooth3");


    // Scale and offset values to give vertex heights in range 1 to 11.
    for (var x=0;x<32;x++)
    {
      for (var z=0;z<32;z++)
      {
        mapArr[x][z] = MapProcessor.scaleAndOffset(mapArr[x][z], scale:heightScale);
      }
    }
    verify(mapArr, landscape_bcd, "scaled");

    // Two de-spike passes, each across z-axis then x-axis.
    for (var i=0;i<2;i++)
    {
        mapArr = MapProcessor.despikeMap(mapArr, "z");
        mapArr = MapProcessor.despikeMap(mapArr, "x");
    }
    verify(mapArr, landscape_bcd, "despike3");


    // Add shape codes for each tile, to simplify examining the landscape.
    mapArr = MapProcessor.addTileShapes(mapArr);
    verify(mapArr, landscape_bcd, "shape");

    // Finally, swap the high and low nibbles in each byte for the final format.
    mapArr = MapProcessor.swapNibbles(mapArr);
    verify(mapArr, landscape_bcd, "swap");


    return mapArr;
  }

  /// Convert array data to in-memory format used by game
  static Uint8List arrToMemory(List<List<int>> mapArr)
  {
    var data = Uint8List(1024);
    for(int i = 0; i<1024; i++)
    {
      data[i] = CoordinateUtils.AtOffset(mapArr, i);
    }
    return data;
  }

  /// Verify the map data against golden images, if they exist
  static void verify(List<List<int>> mapArr, landscape_bcd, String name)
  {
    var f = format('{:04d}', landscape_bcd);
    var filename = "golden\\${f}_${name}.bin";
    var file = File(filename);
    if (file.existsSync())
    {
      var correctValues = file.readAsBytesSync();
      var data = arrToMemory(mapArr);
      for(int i=0;i<1024;i++)
      {
        if (correctValues[i] != data[i])
        {
          throw new Exception("${name} Value does not match at index ${i}");
        }
      }
    }
  }
}

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    print("Usage: dart program.dart <seed>");
    return;
  }
  
  int seed = int.tryParse(arguments[0], radix:16) ?? 0;
  List<List<int>> landscape = LandscapeGenerator.generateLandscape(seed);
  
  print("Generated Landscape with seed: $seed");
  //for (var row in landscape) {
  //  print(row);
  //}
}
