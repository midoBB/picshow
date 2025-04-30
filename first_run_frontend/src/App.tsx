import {
  Theme,
  Card,
  Flex,
  Text,
  TextField,
  Slider,
  Button,
  Dialog,
  Select,
  IconButton,
} from "@radix-ui/themes";
import "@radix-ui/themes/styles.css";
import { useForm, Controller } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { useState } from "react";
import FolderBrowserDialog from "./FolderBrowserDialog";
import { FolderIcon } from "lucide-react";

const isValidLinuxDirectory = (path: string) => {
  return /^\/(?:[^/\0]+\/)+$|^\/?$/gm.test(path);
};

const configSchema = z.object({
  folderPath: z
    .string()
    .min(1, "Folder path is required")
    .refine(isValidLinuxDirectory, {
      message: "Invalid Linux directory path",
    }),
  dbPath: z
    .string()
    .min(1, "Database path is required")
    .refine(isValidLinuxDirectory, {
      message: "Invalid Linux directory path",
    }),
  backupFolderPath: z
    .string()
    .min(1, "Backup folder path is required")
    .refine(isValidLinuxDirectory, {
      message: "Invalid Linux directory path",
    }),
  hashSize: z.number().int().min(32).max(2048).default(128),
  batchSize: z.number().int().min(1).max(100).default(10),
  concurrency: z.number().int().min(1).max(32).default(3),
  maxThumbnailSize: z.number().int().min(240).max(1024).default(480),
  refreshInterval: z.number().int().min(1).max(100).default(72),
  cacheSizeMB: z.number().int().min(20).max(1024).default(64),
  port: z.number().int().min(1024).max(65535).default(8281),
  logLevel: z.enum(["Debug", "Info", "Warn", "Error"]).default("Info"),
  lockSecret: z.string().default(btoa(generateUUID())),
});

// Public Domain/MIT
// https://stackoverflow.com/a/8809472
function generateUUID() {
  var d = new Date().getTime(); //Timestamp
  var d2 =
    (typeof performance !== "undefined" &&
      performance.now &&
      performance.now() * 1000) ||
    0; //Time in microseconds since page-load or 0 if unsupported
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
    var r = Math.random() * 16; //random number between 0 and 16
    if (d > 0) {
      //Use timestamp until depleted
      r = (d + r) % 16 | 0;
      d = Math.floor(d / 16);
    } else {
      //Use microseconds since page-load if supported
      r = (d2 + r) % 16 | 0;
      d2 = Math.floor(d2 / 16);
    }
    return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
  });
}
type FolderFieldName = "folderPath" | "dbPath" | "backupFolderPath";
const ConfigInstallWizard = () => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitResult, setSubmitResult] = useState<{
    success: boolean;
    message: string;
  } | null>(null);
  const {
    control,
    handleSubmit,
    formState: { errors },
    setValue,
  } = useForm({
    resolver: zodResolver(configSchema),
    defaultValues: {
      port: 8281,
      batchSize: 10,
      concurrency: 8,
      folderPath: "",
      dbPath: "",
      backupFolderPath: "",
      hashSize: 512,
      maxThumbnailSize: 720,
      refreshInterval: 72,
      cacheSizeMB: 128,
      logLevel: "Info" as "Debug" | "Info" | "Warn" | "Error",
      lockSecret: btoa(generateUUID()),
    },
  });

  const [folderDialogOpen, setFolderDialogOpen] = useState(false);
  const [currentFolderField, setCurrentFolderField] =
    useState<FolderFieldName | null>(null);

  const onSubmit = async (data: z.infer<typeof configSchema>) => {
    setIsSubmitting(true);
    try {
      const response = await fetch("/api/config", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(data),
      });

      if (response.ok) {
        setSubmitResult({
          success: true,
          message:
            "Configuration saved successfully. The application will now restart.",
        });
      } else {
        const errorData = await response.json();
        setSubmitResult({
          success: false,
          message: `Error: ${errorData.error}`,
        });
      }
    } catch (error: unknown) {
      setSubmitResult({ 
        success: false, 
        message: `Error: ${error instanceof Error ? error.message : String(error)}` 
      });
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleDialogClose = () => {
    if (submitResult?.success) {
      window.location.reload();
    } else {
      setSubmitResult(null);
    }
  };
  const openFolderBrowser = (fieldName: FolderFieldName) => {
    setCurrentFolderField(fieldName);
    setFolderDialogOpen(true);
  };

  const handleFolderSelect = (path: string) => {
    if (currentFolderField) {
      setValue(currentFolderField, path);
    }
  };

  return (
    <Theme
      accentColor="mint"
      grayColor="gray"
      panelBackground="solid"
      scaling="100%"
      radius="full"
      appearance="dark"
    >
      <Flex align="center" justify="center" style={{ minHeight: "100vh" }}>
        <Card size="4" style={{ width: "100%", maxWidth: "640px" }}>
          <form onSubmit={handleSubmit(onSubmit)}>
            <Flex direction="column" gap="4">
              <Text size="5" weight="bold">
                Config Install Wizard
              </Text>

              <label>
                <Text as="div" size="2" mb="1" weight="bold">
                  Library Folder Path Ending In /
                </Text>
                <Flex gap="2">
                  <Controller
                    name="folderPath"
                    control={control}
                    render={({ field }) => (
                      <TextField.Root
                        {...field}
                        placeholder="Select the path where your library is located"
                        style={{ width: "100%" }}
                      />
                    )}
                  />
                  <IconButton
                    type="button"
                    onClick={() => openFolderBrowser("folderPath")}
                    variant="soft"
                  >
                    <FolderIcon width="16" height="16" />
                  </IconButton>
                </Flex>
                {errors.folderPath && (
                  <Text color="red" size="1">
                    {errors.folderPath.message}
                  </Text>
                )}
              </label>

              <label>
                <Text as="div" size="2" mb="1" weight="bold">
                  Database Folder Path Ending In /
                </Text>
                <Flex gap="2">
                  <Controller
                    name="dbPath"
                    control={control}
                    render={({ field }) => (
                      <TextField.Root
                        {...field}
                        placeholder="Select the path for your database"
                        style={{ width: "100%" }}
                      />
                    )}
                  />
                  <IconButton
                    type="button"
                    onClick={() => openFolderBrowser("dbPath")}
                    variant="soft"
                  >
                    <FolderIcon width="16" height="16" />
                  </IconButton>
                </Flex>
                {errors.dbPath && (
                  <Text color="red" size="1">
                    {errors.dbPath.message}
                  </Text>
                )}
              </label>

              <label>
                <Text as="div" size="2" mb="1" weight="bold">
                  Backup Folder Path Ending In /
                </Text>
                <Flex gap="2">
                  <Controller
                    name="backupFolderPath"
                    control={control}
                    render={({ field }) => (
                      <TextField.Root
                        {...field}
                        placeholder="Select the path for your backup folder"
                        style={{ width: "100%" }}
                      />
                    )}
                  />
                  <IconButton
                    type="button"
                    onClick={() => openFolderBrowser("backupFolderPath")}
                    variant="soft"
                  >
                    <FolderIcon width="16" height="16" />
                  </IconButton>
                </Flex>
                {errors.backupFolderPath && (
                  <Text color="red" size="1">
                    {errors.backupFolderPath.message}
                  </Text>
                )}
              </label>
              <Controller
                name="hashSize"
                control={control}
                render={({ field }) => (
                  <Flex direction="column" gap="2">
                    <Text as="label" size="2" weight="bold">
                      Hash Size (32-2048 KB)
                    </Text>
                    <Flex gap="2" align="center">
                      <Slider
                        value={[field.value]}
                        onValueChange={(value) => field.onChange(value[0])}
                        min={32}
                        max={2048}
                        step={32}
                        style={{ flexGrow: 1 }}
                      />
                      <TextField.Root
                        style={{ width: "80px" }}
                        type="number"
                        value={field.value}
                        onChange={(e) => field.onChange(Number(e.target.value))}
                        min={32}
                        max={2048}
                      ></TextField.Root>
                      <Text size="2">KB</Text>
                    </Flex>
                    {errors.hashSize && (
                      <Text color="red" size="1">
                        {errors.hashSize.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />

              <Controller
                name="maxThumbnailSize"
                control={control}
                render={({ field }) => (
                  <Flex direction="column" gap="2">
                    <Text as="label" size="2" weight="bold">
                      Max Thumbnail Size (240-1024 px)
                    </Text>
                    <Flex gap="2" align="center">
                      <Slider
                        value={[field.value]}
                        onValueChange={(value) => field.onChange(value[0])}
                        min={240}
                        max={1024}
                        step={16}
                        style={{ flexGrow: 1 }}
                      />
                      <TextField.Root
                        style={{ width: "80px" }}
                        type="number"
                        value={field.value}
                        onChange={(e) => field.onChange(Number(e.target.value))}
                        min={240}
                        max={1024}
                      ></TextField.Root>
                      <Text size="2">px</Text>
                    </Flex>
                    {errors.maxThumbnailSize && (
                      <Text color="red" size="1">
                        {errors.maxThumbnailSize.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />

              <Controller
                name="concurrency"
                control={control}
                render={({ field }) => (
                  <Flex direction="column" gap="2">
                    <Text as="label" size="2" weight="bold">
                      Concurrency (1-32 threads)
                    </Text>
                    <Flex gap="2" align="center">
                      <Slider
                        value={[field.value]}
                        onValueChange={(value) => field.onChange(value[0])}
                        min={1}
                        max={32}
                        step={1}
                        style={{ flexGrow: 1 }}
                      />
                      <TextField.Root
                        style={{ width: "80px" }}
                        type="number"
                        value={field.value}
                        onChange={(e) => field.onChange(Number(e.target.value))}
                        min={1}
                        max={32}
                      ></TextField.Root>
                    </Flex>
                    {errors.concurrency && (
                      <Text color="red" size="1">
                        {errors.concurrency.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />
              <Controller
                name="port"
                control={control}
                render={({ field }) => (
                  <Flex direction="column" gap="2">
                    <Text as="label" size="2" weight="bold">
                      Port (1024-65535)
                    </Text>
                    <TextField.Root
                      {...field}
                      type="number"
                      placeholder="Enter the port number"
                    />
                    {errors.port && (
                      <Text color="red" size="1">
                        {errors.port.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />
              <Controller
                name="batchSize"
                control={control}
                render={({ field }) => (
                  <Flex direction="column" gap="2">
                    <Text as="label" size="2" weight="bold">
                      Batch Size (1-100 files)
                    </Text>
                    <Flex gap="2" align="center">
                      <Slider
                        value={[field.value]}
                        onValueChange={(value) => field.onChange(value[0])}
                        min={1}
                        max={100}
                        step={4}
                        style={{ flexGrow: 1 }}
                      />
                      <TextField.Root
                        style={{ width: "80px" }}
                        type="number"
                        value={field.value}
                        onChange={(e) => field.onChange(Number(e.target.value))}
                        min={1}
                        max={100}
                      ></TextField.Root>
                    </Flex>
                    {errors.batchSize && (
                      <Text color="red" size="1">
                        {errors.batchSize.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />
              <Controller
                name="refreshInterval"
                control={control}
                render={({ field }) => (
                  <Flex direction="column" gap="2">
                    <Text as="label" size="2" weight="bold">
                      Refresh Interval (1-100 hours)
                    </Text>
                    <Flex gap="2" align="center">
                      <Slider
                        value={[field.value]}
                        onValueChange={(value) => field.onChange(value[0])}
                        min={1}
                        max={100}
                        step={1}
                        style={{ flexGrow: 1 }}
                      />
                      <TextField.Root
                        style={{ width: "80px" }}
                        type="number"
                        value={field.value}
                        onChange={(e) => field.onChange(Number(e.target.value))}
                        min={1}
                        max={100}
                      ></TextField.Root>
                      <Text size="2">hours</Text>
                    </Flex>
                    {errors.refreshInterval && (
                      <Text color="red" size="1">
                        {errors.refreshInterval.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />

              <Controller
                name="cacheSizeMB"
                control={control}
                render={({ field }) => (
                  <Flex direction="column" gap="2">
                    <Text as="label" size="2" weight="bold">
                      Cache Size (20-1024 MB)
                    </Text>
                    <Flex gap="2" align="center">
                      <Slider
                        value={[field.value]}
                        onValueChange={(value) => field.onChange(value[0])}
                        min={20}
                        max={1024}
                        step={20}
                        style={{ flexGrow: 1 }}
                      />
                      <TextField.Root
                        style={{ width: "80px" }}
                        type="number"
                        value={field.value}
                        onChange={(e) => field.onChange(Number(e.target.value))}
                        min={20}
                        max={1024}
                      />
                      <Text size="2">MB</Text>
                    </Flex>
                    {errors.cacheSizeMB && (
                      <Text color="red" size="1">
                        {errors.cacheSizeMB.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />

              <Controller
                name="logLevel"
                control={control}
                render={({ field }) => (
                  <Flex direction="column" gap="2">
                    <Text as="label" size="2" weight="bold">
                      Log Level
                    </Text>
                    <Select.Root
                      onValueChange={field.onChange}
                      defaultValue={field.value}
                    >
                      <Select.Trigger />
                      <Select.Content>
                        <Select.Item value="Debug">Debug</Select.Item>
                        <Select.Item value="Info">Info</Select.Item>
                        <Select.Item value="Warn">Warn</Select.Item>
                        <Select.Item value="Error">Error</Select.Item>
                      </Select.Content>
                    </Select.Root>
                    {errors.logLevel && (
                      <Text color="red" size="1">
                        {errors.logLevel.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />
              <Button type="submit" disabled={isSubmitting}>
                {isSubmitting ? "Saving..." : "Save Configuration"}
              </Button>
            </Flex>
          </form>
        </Card>
      </Flex>
      <Dialog.Root
        open={submitResult !== null}
        onOpenChange={handleDialogClose}
      >
        <Dialog.Content>
          <Dialog.Title>
            {submitResult?.success ? "Success" : "Error"}
          </Dialog.Title>
          <Dialog.Description>
            {submitResult?.message}
            {submitResult?.success && (
              <Text as="p" style={{ marginTop: "1rem" }}>
                Click OK to reload the page and start the application with the
                new configuration.
              </Text>
            )}
          </Dialog.Description>
          <Flex justify="end" mt="4">
            <Dialog.Close>
              <Button>{submitResult?.success ? "OK" : "Close"}</Button>
            </Dialog.Close>
          </Flex>
        </Dialog.Content>
      </Dialog.Root>
      <FolderBrowserDialog
        open={folderDialogOpen}
        onOpenChange={setFolderDialogOpen}
        onSelect={handleFolderSelect}
        title={`Select ${currentFolderField?.replace("Path", "") || "Folder"}`}
      />
    </Theme>
  );
};

export default ConfigInstallWizard;
