import * as Dialog from "@radix-ui/react-dialog";
import * as Checkbox from "@radix-ui/react-checkbox";
import useAppState from "@/state";

interface ConfirmDialogProps {
  isOpen: boolean;
  onOpenChange: (open: boolean) => void;
  onConfirm: () => void;
  dontAskAgain: boolean;
  setDontAskAgain: (value: boolean) => void;
  files: Array<{
    ID: number;
    MimeType: string;
    Image?: { ThumbnailBase64: string };
    Video?: { ThumbnailBase64: string };
  }>;
}

const ConfirmDialog: React.FC<ConfirmDialogProps> = ({
  isOpen,
  onOpenChange,
  onConfirm,
  dontAskAgain,
  setDontAskAgain,
  files,
}) => {
  const { isDarkMode } = useAppState();

  return (
    <Dialog.Root open={isOpen} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="bg-blackA9 data-[state=open]:animate-overlayShow fixed inset-0" />
        <Dialog.Content
          className={`data-[state=open]:animate-contentShow fixed top-[50%] left-[50%] max-h-[85vh] w-[90vw] max-w-[500px] translate-x-[-50%] translate-y-[-50%] rounded-[6px] ${isDarkMode ? "bg-gray-800 text-white" : "bg-white text-gray-900"} p-[25px] shadow-[hsl(206_22%_7%_/_35%)_0px_10px_38px_-10px,_hsl(206_22%_7%_/_20%)_0px_10px_20px_-15px] focus:outline-none`}
        >
          <Dialog.Title className="m-0 text-[17px] font-medium">
            Delete Files
          </Dialog.Title>
          <Dialog.Description className="mt-[10px] mb-5 text-[15px] leading-normal">
            You're about to delete {files.length} file
            {files.length > 1 ? "s" : ""}. This action cannot be undone.
          </Dialog.Description>
          <div className="max-h-[300px] overflow-y-auto mb-5">
            <div className="grid grid-cols-4 gap-2">
              {files.map((file) => (
                <div key={file.ID} className="relative w-full pt-[100%]">
                  <img
                    src={
                      file.MimeType === "video"
                        ? file.Video?.ThumbnailBase64
                        : file.Image?.ThumbnailBase64
                    }
                    alt={`File ${file.ID}`}
                    className="absolute top-0 left-0 w-full h-full object-cover rounded-md"
                  />
                  {file.MimeType === "video" && (
                    <div className="absolute inset-0 flex items-center justify-center">
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        className="h-8 w-8 text-white opacity-75"
                        viewBox="0 0 20 20"
                        fill="currentColor"
                      >
                        <path
                          fillRule="evenodd"
                          d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z"
                          clipRule="evenodd"
                        />
                      </svg>
                    </div>
                  )}
                </div>
              ))}
            </div>
          </div>
          <div className="flex items-center space-x-2 mb-5">
            <Checkbox.Root
              className={`flex h-[25px] w-[25px] appearance-none items-center justify-center rounded-[4px] ${isDarkMode ? "bg-gray-700" : "bg-white"} shadow-[0_2px_10px] shadow-blackA7 outline-none hover:bg-violet3 focus:shadow-[0_0_0_2px] focus:shadow-black`}
              id="dontAskAgain"
              checked={dontAskAgain}
              onCheckedChange={(checked) => setDontAskAgain(checked === true)}
            >
              <Checkbox.Indicator className="text-violet11">
                <svg
                  width="15"
                  height="15"
                  viewBox="0 0 15 15"
                  fill="none"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    d="M11.4669 3.72684C11.7558 3.91574 11.8369 4.30308 11.648 4.59198L7.39799 11.092C7.29783 11.2452 7.13556 11.3467 6.95402 11.3699C6.77247 11.3931 6.58989 11.3355 6.45446 11.2124L3.70446 8.71241C3.44905 8.48022 3.43023 8.08494 3.66242 7.82953C3.89461 7.57412 4.28989 7.55529 4.5453 7.78749L6.75292 9.79441L10.6018 3.90792C10.7907 3.61902 11.178 3.53795 11.4669 3.72684Z"
                    fill="currentColor"
                    fillRule="evenodd"
                    clipRule="evenodd"
                  ></path>
                </svg>
              </Checkbox.Indicator>
            </Checkbox.Root>
            <label className="text-[15px] leading-none" htmlFor="dontAskAgain">
              Don't ask again
            </label>
          </div>
          <div className="mt-[25px] flex justify-end">
            <Dialog.Close asChild>
              <button
                className={`${isDarkMode ? "bg-gray-700 text-white hover:bg-gray-600" : "bg-green4 text-green11 hover:bg-green5"} inline-flex h-[35px] items-center justify-center rounded-[4px] px-[15px] font-medium leading-none focus:shadow-[0_0_0_2px] focus:outline-none mr-[10px]`}
              >
                Cancel
              </button>
            </Dialog.Close>
            <Dialog.Close asChild>
              <button
                className={`${isDarkMode ? "bg-red-700 text-white hover:bg-red-600" : "bg-red4 text-red11 hover:bg-red5"} inline-flex h-[35px] items-center justify-center rounded-[4px] px-[15px] font-medium leading-none focus:shadow-[0_0_0_2px] focus:outline-none`}
                onClick={onConfirm}
              >
                Delete
              </button>
            </Dialog.Close>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
};

export default ConfirmDialog;
