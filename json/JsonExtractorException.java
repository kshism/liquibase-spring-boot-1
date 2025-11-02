package com.example.JsonExtractor;

public class JsonExtractorException extends Exception {
    private final int exitCode;

    public JsonExtractorException(String message, int exitCode) {
        super(message);
        this.exitCode = exitCode;
    }

    public JsonExtractorException(String message) {
        this(message, 1);
    }

    public int getExitCode() {
        return exitCode;
    }
}