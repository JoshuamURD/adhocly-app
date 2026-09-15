import { defineConfig } from "orval";

export default defineConfig({
  adhocly: {
    input: { target: "./server/openapi.json" },
    output: {
      target: "./src/lib/api/generated.ts",
      client: "svelte-query",
      clean: true,
      override: {
        mutator: {
          path: "./src/lib/api-fetch.ts",
          name: "apiFetch",
        },
        query: {
          useInvalidate: true,
          mutationInvalidates: [
            {
              onMutations: ["createTask", "updateTask", "deleteTask", "toggleTask"],
              invalidates: ["listTasks"],
            },
            {
              // Deleting a project moves its tasks to Inbox, so reload both lists.
              onMutations: [
                "createProject",
                "updateProject",
                "deleteProject",
                "moveProject",
                "createMetadataField",
                "updateMetadataField",
                "deleteMetadataField",
                "setProjectMetadata",
              ],
              invalidates: ["listProjects", "listTasks"],
            },
            {
              // Deleting a folder hands its projects to the parent folder, so they move too.
              onMutations: ["createFolder", "updateFolder", "deleteFolder"],
              invalidates: ["listFolders", "listProjects"],
            },
          ],
        },
      },
    },
  },
});
