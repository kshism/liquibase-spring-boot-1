package com.example.JsonExtractor;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

public class JsonExtractorTest {
    @TempDir
    Path tempDir;

    private Path createTestFile(String content) throws IOException {
        Path testFile = tempDir.resolve("test.json");
        Files.write(testFile, content.getBytes(StandardCharsets.UTF_8));
        return testFile;
    }

    private List<String> readOutputFile(Path outputFile) throws IOException {
        return Files.readAllLines(outputFile).stream()
               .filter(s -> !s.isBlank())
               .collect(Collectors.toList());
    }

    @Test
    void testBasicExtraction() throws Exception {
        String json = "{\n" +
                     "  \"accounts\": [\n" +
                     "    {\"id\": 1, \"name\": \"test1\"},\n" +
                     "    {\"id\": 2, \"name\": \"test2\"}\n" +
                     "  ]\n" +
                     "}\n";

        Path inputFile = createTestFile(json);
        Path outputPath = tempDir.resolve("output");
        Files.createDirectories(outputPath);
        
        String[] args = {
            "--in", inputFile.toString(),
            "--out", outputPath.toString() + "/output",
            "--suffix-format", "part%04d",
            "--split", "2"
        };
        
        JsonExtractor.runMain(args);

        Path part1 = outputPath.resolve("output.part0001.ndjson");
        assertTrue(Files.exists(part1), "Output file should exist");
        
        List<String> lines = readOutputFile(part1);
        assertEquals(2, lines.size(), "Should have exactly two objects");
        assertTrue(lines.get(0).contains("\"id\": 1"), "First object should have id 1");
        assertTrue(lines.get(1).contains("\"id\": 2"), "Second object should have id 2");
    }

    @Test
    void testLargeFileHandling() throws Exception {
        StringBuilder json = new StringBuilder("{\"accounts\": [");
        for (int i = 0; i < 1000; i++) {
            if (i > 0) json.append(",");
            json.append(String.format("{\"id\": %d, \"name\": \"test%d\"}", i, i));
        }
        json.append("]}");

        Path inputFile = createTestFile(json.toString());
        Path outputPath = tempDir.resolve("large_output");
        Files.createDirectories(outputPath);
        
        String[] args = {
            "--in", inputFile.toString(),
            "--out", outputPath.toString() + "/output",
            "--suffix-format", "part%04d",
            "--split", "100"
        };
        
        JsonExtractor.runMain(args);

        // Verify all files exist and contain correct number of objects
        for (int i = 1; i <= 10; i++) {
            Path partFile = outputPath.resolve(String.format("output.part%04d.ndjson", i));
            assertTrue(Files.exists(partFile), "Part file " + i + " should exist");
            
            List<String> lines = readOutputFile(partFile);
            assertEquals(100, lines.size(), "Each part file should have 100 objects");
        }
    }

    @Test
    void testProgressOutput() throws Exception {
        String json = "{\"accounts\": [" + 
                     "{ \"id\": 1 }," +
                     "{ \"id\": 2 }" +
                     "]}";

        Path inputFile = createTestFile(json);
        Path outputPath = tempDir.resolve("progress_output");
        Files.createDirectories(outputPath);

        ByteArrayOutputStream errContent = new ByteArrayOutputStream();
        PrintStream originalErr = System.err;
        System.setErr(new PrintStream(errContent));
        
        try {
            String[] args = {
                "--in", inputFile.toString(),
                "--out", outputPath.toString() + "/output",
                "--suffix-format", "part%04d",
                "--split", "1",
                "--show-progress"
            };            
            JsonExtractor.runMain(args);
        } finally {
            System.setErr(originalErr);
        }

        String output = errContent.toString();
        assertTrue(output.contains("Processing..."), "Should show processing message");
    }

    @Test
    void testCustomKeyExtraction() throws Exception {
        String json = "{\n" +
                     "  \"users\": [\n" +
                     "    {\"id\": 1},\n" +
                     "    {\"id\": 2}\n" +
                     "  ]\n" +
                     "}\n";

        Path inputFile = createTestFile(json);
        Path outputPath = tempDir.resolve("custom_key_output");
        Files.createDirectories(outputPath);
        
        String[] args = {
            "--in", inputFile.toString(),
            "--out", outputPath.toString() + "/output",
            "--suffix-format", "part%04d",
            "--split", "2",
            "--key", "users"
        };
        
        JsonExtractor.runMain(args);

        Path part1 = outputPath.resolve("output.part0001.ndjson");
        assertTrue(Files.exists(part1), "Output file should exist");
        
        List<String> lines = readOutputFile(part1);
        assertEquals(2, lines.size(), "Should have exactly two objects");
    }

    @Test
    void testNestedJsonHandling() throws Exception {
        String json = "{\n" +
                     "  \"accounts\": [\n" +
                     "    {\"id\": 1, \"details\": {\"active\": true}},\n" +
                     "    {\"id\": 2, \"details\": {\"active\": false}}\n" +
                     "  ]\n" +
                     "}\n";

        Path inputFile = createTestFile(json);
        Path outputPath = tempDir.resolve("nested_output");
        Files.createDirectories(outputPath);
        
        String[] args = {
            "--in", inputFile.toString(),
            "--out", outputPath.toString() + "/output",
            "--suffix-format", "part%04d",
            "--split", "2"
        };
        
        JsonExtractor.runMain(args);

        Path part1 = outputPath.resolve("output.part0001.ndjson");
        assertTrue(Files.exists(part1), "Output file should exist");
        
        List<String> lines = readOutputFile(part1);
        assertEquals(2, lines.size(), "Should have exactly two objects");
        assertTrue(lines.get(0).contains("\"details\""), "Should preserve nested objects");
    }

    @Test
    void testMalformedJson() throws IOException {
        String json = "{\"accounts\": [{\"id\": 1},"; // Incomplete JSON
        Path inputFile = createTestFile(json);
        Path outputPath = tempDir.resolve("malformed_output");
        Files.createDirectories(outputPath);

        String[] args = {
            "--in", inputFile.toString(),
            "--out", outputPath.toString() + "/output",
            "--suffix-format", "part%04d",
            "--split", "2"
        };

        assertThrows(JsonExtractorException.class, () -> {
            JsonExtractor.runMain(args);
        }, "Should throw exception for malformed JSON");
    }

    @Test
    void testInvalidArrayValue() throws IOException {
        String json = "{\"accounts\": {\"id\": 1}}"; // Not an array
        Path inputFile = createTestFile(json);
        Path outputPath = tempDir.resolve("invalid_output");
        Files.createDirectories(outputPath);

        String[] args = {
            "--in", inputFile.toString(),
            "--out", outputPath.toString() + "/output",
            "--suffix-format", "part%04d",
            "--split", "2"
        };

        assertThrows(JsonExtractorException.class, () -> {
            JsonExtractor.runMain(args);
        }, "Should throw exception when value is not an array");
    }

    @Test
    void testMissingKey() throws IOException {
        String json = "{\"wrong_key\": [{\"id\": 1}]}";
        Path inputFile = createTestFile(json);
        Path outputPath = tempDir.resolve("missing_key_output");
        Files.createDirectories(outputPath);

        String[] args = {
            "--in", inputFile.toString(),
            "--out", outputPath.toString() + "/output",
            "--suffix-format", "part%04d",
            "--split", "2"
        };

        assertThrows(JsonExtractorException.class, () -> {
            JsonExtractor.runMain(args);
        }, "Should throw exception when key is not found");
    }

    @Test
    void testCustomSuffixFormat() throws Exception {
        String json = "{\n" +
                     "  \"accounts\": [\n" +
                     "    {\"id\": 1},\n" +
                     "    {\"id\": 2}\n" +
                     "  ]\n" +
                     "}\n";

        Path inputFile = createTestFile(json);
        Path outputPath = tempDir.resolve("custom_suffix_output");
        Files.createDirectories(outputPath);
        
        // Test various suffix formats
        String[][] formats = {
            {"part%04d", "test.part0001.ndjson"},
            {"chunk_%d", "test.chunk_1.ndjson"},
            {"%03d", "test.001.ndjson"},
            {"_%04d_", "test._0001_.ndjson"}
        };

        for (String[] format : formats) {
            String suffixFormat = format[0];
            String expectedFile = format[1];
            
            String[] args = {
                "--in", inputFile.toString(),
                "--out", outputPath.toString() + "/test",
                "--suffix-format", suffixFormat,
                "--split", "10" // Large enough to keep all in one file
            };
            
            JsonExtractor.runMain(args);

            Path outFile = outputPath.resolve(expectedFile);
            assertTrue(Files.exists(outFile), 
                String.format("Output file with format %s should exist: %s", 
                    suffixFormat, expectedFile));
            
            List<String> lines = readOutputFile(outFile);
            assertEquals(2, lines.size(), 
                String.format("File with format %s should contain both objects", 
                    suffixFormat));
            assertTrue(lines.get(0).contains("\"id\": 1"), 
                String.format("First object in %s should have id 1", expectedFile));
            assertTrue(lines.get(1).contains("\"id\": 2"), 
                String.format("Second object in %s should have id 2", expectedFile));

            // Clean up for next test
            Files.delete(outFile);
        }
    }
}