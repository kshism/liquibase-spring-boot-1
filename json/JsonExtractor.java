package com.example.JsonExtractor;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;

/**
 * JsonExtractor - A utility for extracting JSON array elements to NDJSON format
 */
public class JsonExtractor {
    private static int BUFFER_SIZE = 64 * 1024; // default buffer size
    private static byte[] KEY_BYTES = "\"accounts\"".getBytes(StandardCharsets.UTF_8);
    private static final int MAX_OBJECT_SIZE = 10 * 1024 * 1024; // 10MB max
    private static boolean SHOW_PROGRESS = false;
    private static boolean COUNT_ONLY = false;
    private static String SUFFIX_FORMAT = "part%04d";

    public static void main(String[] args) {
        try {
            runMain(args);
        } catch (JsonExtractorException e) {
            System.err.println("Error: " + e.getMessage());
            System.exit(e.getExitCode());
        } catch (Exception e) {
            System.err.println("Error: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }

    public static void runMain(String[] args) throws Exception {
        String input = null;
        String outPrefix = null;
        Integer split = null;
        String keyName = "accounts"; // default key

        if (args == null || args.length == 0) {
            printHelpAndExit();
        }

        for (int i = 0; i < args.length; ++i) {
            switch (args[i]) {
                case "--help":
                case "-h":
                    printHelpAndExit();
                    break;
                case "--in":
                    if (++i < args.length) input = args[i];
                    else usageAndExit();
                    break;
                case "--out":
                    if (++i < args.length) outPrefix = args[i];
                    else usageAndExit();
                    break;
                case "--split":
                    if (++i < args.length) split = Integer.parseInt(args[i]);
                    else usageAndExit();
                    break;
                case "--buffer":
                    if (++i < args.length) {
                        BUFFER_SIZE = Integer.parseInt(args[i]);
                        System.err.println("[Config] Buffer size set to " + BUFFER_SIZE + " bytes");
                    } else usageAndExit();
                    break;
                case "--key":
                    if (++i < args.length) {
                        keyName = args[i];
                        System.err.println("[Config] Extracting array under key \"" + keyName + "\"");
                    } else usageAndExit();
                    break;
                case "--suffix-format":
                    if (++i < args.length) {
                        SUFFIX_FORMAT = args[i];
                        // Ensure that the suffix format does not replace '0' with a blank space
                        SUFFIX_FORMAT = SUFFIX_FORMAT.replace(" ", "0");
                        System.err.println("[Config] Using suffix format \"" + SUFFIX_FORMAT + "\"");
                    } else usageAndExit();
                    break;
                case "--show-progress":
                    SHOW_PROGRESS = true;
                    break;
                case "--count-only":
                    COUNT_ONLY = true;
                    break;
                default:
                    System.err.println("Unknown arg: " + args[i]);
                    usageAndExit();
            }
        }

        if (input == null) usageAndExit();
        KEY_BYTES = ("\"" + keyName + "\"").getBytes(StandardCharsets.UTF_8);

        Path inPath = Paths.get(input).normalize();
        if (!Files.exists(inPath)) {
            throw new JsonExtractorException("Input file does not exist: " + input, 2);
        }

        if (outPrefix == null && !COUNT_ONLY) usageAndExit();
        if (split == null) split = Integer.MAX_VALUE;

        try {
            int written = extract(inPath, outPrefix, split, COUNT_ONLY);
            
            if (COUNT_ONLY) {
                System.out.println("Total records under key \"" + keyName + "\": " + written);
            } else {
                System.err.println("Done. Wrote " + written + " records.");
            }
        } catch (IOException e) {
            throw new JsonExtractorException("Malformed JSON: " + e.getMessage(), 1);
        }
    }

    private static void usageAndExit() throws JsonExtractorException {
        System.err.println("Usage: java JsonExtractor --in <input.json> [--out <prefix>] [--key <arrayKey>] [--split <records>] [--buffer <bytes>] [--suffix-format <format>] [--show-progress] [--count-only]");
        System.err.println("Use --help for details.");
        throw new JsonExtractorException("Invalid command line arguments", 2);
    }

    private static void printHelpAndExit() throws JsonExtractorException {
        System.out.println("JsonExtractor - Extract JSON array elements to NDJSON");
        System.out.println("\nUsage:\n  java JsonExtractor --in <input.json> [options]\n");
        System.out.println("Options:");
        System.out.println("  --help, -h          Show this help message");
        System.out.println("  --in <file>         Input JSON file (required)");
        System.out.println("  --out <prefix>      Output NDJSON file prefix");
        System.out.println("  --key <name>        Array key to extract (default: 'accounts')");
        System.out.println("  --split <num>       Records per file (default: all in one)");
        System.out.println("  --buffer <bytes>    Set buffer size (default: 65536)");
        System.out.println("  --suffix-format <f>  Set output file suffix format (default: part%04d)");
        System.out.println("  --show-progress     Print progress every 1000 records");
        System.out.println("  --count-only        Print only record count and exit\n");
        throw new JsonExtractorException("Help displayed", 0);
    }

    private static int extract(Path inputFile, String outPrefix, int splitSize, boolean countOnly) 
            throws IOException, JsonExtractorException {
        if (!Files.exists(inputFile)) {
            throw new JsonExtractorException("No objects found", 0);
        }

        long arrayStart = findArrayOffset(inputFile);
        if (arrayStart < 0) {
            throw new JsonExtractorException("No objects found", 0);
        }

        // Create output directory if needed
        if (!countOnly && outPrefix != null) {
            Path outputPath = Paths.get(outPrefix);
            if (outputPath.getParent() != null) {
                Files.createDirectories(outputPath.getParent());
            }
        }

        return processObjects(inputFile, outPrefix, arrayStart, splitSize, countOnly);
    }

    private static long findArrayOffset(Path p) throws IOException, JsonExtractorException {
        try (BufferedInputStream in = new BufferedInputStream(Files.newInputStream(p), BUFFER_SIZE)) {
            int matchIdx = 0;
            int b;
            long offset = 0;

            // Search for the key
            while ((b = in.read()) != -1) {
                offset++;
                if (b == KEY_BYTES[matchIdx]) {
                    matchIdx++;
                    if (matchIdx == KEY_BYTES.length) {
                        // Skip whitespace until colon
                        while ((b = in.read()) != -1) {
                            offset++;
                            if (b == ':') break;
                            if (!isWhitespace((byte)b)) {
                                return -1;
                            }
                        }
                        if (b == -1) {
                            throw new JsonExtractorException("Malformed JSON: Unexpected end of input", 1);
                        }

                        // Skip whitespace until open bracket
                        while ((b = in.read()) != -1) {
                            offset++;
                            if (b == '[') return offset;
                            if (!isWhitespace((byte)b)) {
                                throw new JsonExtractorException("Malformed JSON: Expected array value", 1);
                            }
                        }
                        throw new JsonExtractorException("Malformed JSON: Unexpected end of input", 1);
                    }
                } else {
                    matchIdx = (b == KEY_BYTES[0]) ? 1 : 0;
                }
            }
            return -1;
        }
    }

    private static boolean isWhitespace(byte b) {
        return b == ' ' || b == '\t' || b == '\r' || b == '\n' || b == ',';
    }

    private static BufferedWriter openOutputFile(String prefix, int fileNumber) throws IOException {
        Path outputPath = Paths.get(prefix + "." + String.format(SUFFIX_FORMAT, fileNumber) + ".ndjson");
        return Files.newBufferedWriter(outputPath, StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
    }

    private static int processObjects(Path inputFile, String outPrefix, long startOffset, int splitSize, boolean countOnly) 
            throws IOException, JsonExtractorException {
        try (RandomAccessFile raf = new RandomAccessFile(inputFile.toFile(), "r")) {
            raf.seek(startOffset);
            try (BufferedInputStream in = new BufferedInputStream(new FileInputStream(raf.getFD()), BUFFER_SIZE)) {
                int objectCount = 0;
                int objectsInCurrentFile = 0;
                int currentFileNumber = 1;
                BufferedWriter writer = null;

                if (!countOnly) {
                    writer = openOutputFile(outPrefix, currentFileNumber);
                }

                ByteArrayOutputStream objBuf = new ByteArrayOutputStream(4096);
                int braceDepth = 0;
                boolean inString = false;
                boolean escape = false;
                int b;

                // Skip any leading whitespace
                while ((b = in.read()) != -1 && isWhitespace((byte)b)) {}
                if (b == ']' || b == -1) return 0;

                do {
                    if (b != '{') {
                        while ((b = in.read()) != -1 && b != '{' && b != ']') {}
                        if (b == ']' || b == -1) break;
                    }

                    objBuf.reset();
                    objBuf.write('{');
                    braceDepth = 1;

                    // Read the complete object
                    boolean complete = false;
                    while ((b = in.read()) != -1) {
                        objBuf.write(b);
                        if (objBuf.size() > MAX_OBJECT_SIZE) {
                            throw new JsonExtractorException("Object exceeds maximum size limit", 1);
                        }

                        if (inString) {
                            if (escape) {
                                escape = false;
                            } else if (b == '\\') {
                                escape = true;
                            } else if (b == '"') {
                                inString = false;
                            }
                        } else {
                            if (b == '"') {
                                inString = true;
                            } else if (b == '{') {
                                braceDepth++;
                            } else if (b == '}') {
                                braceDepth--;
                                if (braceDepth == 0) {
                                    complete = true;
                                    break;
                                }
                            }
                        }
                    }

                    // If we didn't complete reading the object, or we still have unclosed braces
                    if (!complete || braceDepth != 0) {
                        throw new JsonExtractorException("Malformed JSON: Unexpected end of object", 1);
                    }

                    objectCount++;
                    
                    if (!countOnly) {
                        // Replace newlines with spaces in the object
                        byte[] objBytes = objBuf.toByteArray();
                        for (int i = 0; i < objBytes.length; i++) {
                            if (objBytes[i] == '\n' || objBytes[i] == '\r') {
                                objBytes[i] = ' ';
                            }
                        }
                        
                        writer.write(new String(objBytes, StandardCharsets.UTF_8));
                        writer.write('\n');
                        objectsInCurrentFile++;

                        if (objectsInCurrentFile >= splitSize) {
                            writer.close();
                            objectsInCurrentFile = 0;
                            currentFileNumber++;
                            writer = openOutputFile(outPrefix, currentFileNumber);
                        }
                    }

                    if (SHOW_PROGRESS && (objectCount == 1 || objectCount % 1000 == 0)) {
                        System.err.printf("Processing... %d objects%n", objectCount);
                    }

                    // Skip whitespace until next object or end of array
                    while ((b = in.read()) != -1 && isWhitespace((byte)b)) {}

                } while (b != ']' && b != -1);

                if (b != ']') {
                    throw new JsonExtractorException("Malformed JSON: Array not properly closed", 1);
                }

                if (!countOnly && writer != null) {
                    writer.close();
                }

                return objectCount;
            }
        }
    }
}