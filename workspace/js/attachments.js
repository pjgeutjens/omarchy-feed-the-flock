import { request } from './api.js';

export function imageFiles(items) {
  return [...(items || [])].map(item => item instanceof File ? item : item.getAsFile?.())
    .filter(file => file && file.type.startsWith('image/'));
}

export function createAttachmentService({ load, setStatus, showToast }) {
  async function uploadAttachment(noteId, file) {
    if (file.size > 8 * 1024 * 1024) throw new Error('Images must be 8 MB or smaller');
    const data = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(',', 2)[1] || '');
      reader.onerror = () => reject(new Error('Could not read the image'));
      reader.readAsDataURL(file);
    });
    await request('/api/attachment/create', {
      method: 'POST',
      body: JSON.stringify({ noteId, name: file.name || 'clipboard-image', mimeType: file.type, data })
    });
  }

  async function uploadAttachments(noteId, files, existingCount = 0) {
    if (!files.length) return;
    if (existingCount + files.length > 5) {
      setStatus('A note can have at most 5 images.', true);
      return;
    }
    try {
      for (const file of files) await uploadAttachment(noteId, file);
      await load();
      showToast(files.length === 1 ? 'Image attached' : `${files.length} images attached`);
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  return { uploadAttachments };
}
