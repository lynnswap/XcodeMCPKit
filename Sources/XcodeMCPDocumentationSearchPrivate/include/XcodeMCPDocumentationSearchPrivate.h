#ifndef XCODE_MCP_DOCUMENTATION_SEARCH_PRIVATE_H
#define XCODE_MCP_DOCUMENTATION_SEARCH_PRIVATE_H

#ifdef __cplusplus
extern "C" {
#endif

int XCDocSemanticSearchRuntimeAvailable(void);

char *XCDocSemanticSearchCopyResultJSON(
    const char *databaseDirectoryPath,
    const char *embeddingModelName,
    const char *query,
    int limit,
    double timeoutSeconds,
    char **errorMessage
);

void XCDocSemanticSearchFree(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
