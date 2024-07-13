import {
  Theme,
  Card,
  Flex,
  Text,
  TextField,
  Slider,
  Button,
  Dialog,
} from "@radix-ui/themes";
import "@radix-ui/themes/styles.css";
import { useForm, Controller } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { useState } from "react";

const isValidLinuxDirectory = (path: string) => {
  return /^\/(?:[^/\0]+\/)+$|^\/?$/gm.test(path);
};

const configSchema = z.object({
  FolderPath: z
    .string()
    .min(1, "Folder path is required")
    .refine(isValidLinuxDirectory, {
      message: "Invalid Linux directory path",
    }),
  DBPath: z
    .string()
    .min(1, "Database path is required")
    .refine(isValidLinuxDirectory, {
      message: "Invalid Linux directory path",
    }),
  HashSize: z.number().int().min(32).max(2048).default(128),
  MaxThumbnailSize: z.number().int().min(240).max(1024).default(480),
  RefreshInterval: z.number().int().min(1).max(100).default(72),
  CacheSizeMB: z.number().int().min(20).max(1024).default(64),
});

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
  } = useForm({
    resolver: zodResolver(configSchema),
    defaultValues: {
      FolderPath: "",
      DBPath: "",
      HashSize: 128,
      MaxThumbnailSize: 480,
      RefreshInterval: 72,
      CacheSizeMB: 64,
    },
  });

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
    } catch (error) {
      setSubmitResult({ success: false, message: `Error: ${error.message}` });
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
        <Card size="4" style={{ width: "100%", maxWidth: "500px" }}>
          <form onSubmit={handleSubmit(onSubmit)}>
            <Flex direction="column" gap="4">
              <Text size="5" weight="bold">
                Config Install Wizard
              </Text>

              <label>
                <Text as="div" size="2" mb="1" weight="bold">
                  Library Folder Path Ending In /
                </Text>
                <Controller
                  name="FolderPath"
                  control={control}
                  render={({ field }) => (
                    <TextField.Root
                      {...field}
                      placeholder="Enter the path where your library is located"
                    />
                  )}
                />
                {errors.FolderPath && (
                  <Text color="red" size="1">
                    {errors.FolderPath.message}
                  </Text>
                )}
              </label>

              <label>
                <Text as="div" size="2" mb="1" weight="bold">
                  Database Folder Path Ending In /
                </Text>
                <Controller
                  name="DBPath"
                  control={control}
                  render={({ field }) => (
                    <TextField.Root
                      {...field}
                      placeholder="Enter the path where your library is located"
                    />
                  )}
                />
                {errors.DBPath && (
                  <Text color="red" size="1">
                    {errors.DBPath.message}
                  </Text>
                )}
              </label>

              <Controller
                name="HashSize"
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
                    {errors.HashSize && (
                      <Text color="red" size="1">
                        {errors.HashSize.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />

              <Controller
                name="MaxThumbnailSize"
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
                    {errors.MaxThumbnailSize && (
                      <Text color="red" size="1">
                        {errors.MaxThumbnailSize.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />

              <Controller
                name="RefreshInterval"
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
                    {errors.RefreshInterval && (
                      <Text color="red" size="1">
                        {errors.RefreshInterval.message}
                      </Text>
                    )}
                  </Flex>
                )}
              />

              <Controller
                name="CacheSizeMB"
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
                    {errors.CacheSizeMB && (
                      <Text color="red" size="1">
                        {errors.CacheSizeMB.message}
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
    </Theme>
  );
};

export default ConfigInstallWizard;
