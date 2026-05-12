const header = document.querySelector('[data-elevates]');
const copyButton = document.querySelector('[data-copy-target]');
const scrambleTargets = document.querySelectorAll('[data-scramble-in]');
const workflowVideos = document.querySelectorAll('[data-workflow-video]');
const faqTriggers = document.querySelectorAll('[data-faq-trigger]');
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

const setHeaderState = () => {
  header?.classList.toggle('is-scrolled', window.scrollY > 24);
};

const scrambleCharacters = 'abcdefghijklmnopqrstuvwxyz0123456789_/-+=$#@';

const scrambleText = (element, finalText) => {
  if (reducedMotion.matches) {
    element.textContent = finalText;
    return;
  }

  const duration = 1200;
  const start = performance.now();
  element.classList.add('is-scrambling');

  const frame = now => {
    const progress = Math.min((now - start) / duration, 1);
    const reveal = Math.floor(finalText.length * progress);
    const text = Array.from(finalText, (character, index) => {
      if (character.trim() === '' || index < reveal) return character;
      const seed = Math.floor((now / 28 + index * 11) % scrambleCharacters.length);
      return scrambleCharacters[seed];
    }).join('');

    element.textContent = text;

    if (progress < 1) {
      window.requestAnimationFrame(frame);
      return;
    }

    element.textContent = finalText;
    element.classList.remove('is-scrambling');
  };

  window.requestAnimationFrame(frame);
};

const setupScrambleIn = () => {
  if (!scrambleTargets.length) return;

  scrambleTargets.forEach(target => {
    const finalText = target.textContent;
    const copyRoot = target.closest('[id]');

    if (copyRoot) copyRoot.dataset.copyText = finalText;
  });

  const observer = new IntersectionObserver(
    entries => {
      entries.forEach(entry => {
        if (!entry.isIntersecting) return;

        const target = entry.target;
        observer.unobserve(target);
        scrambleText(target, target.closest('[id]')?.dataset.copyText || target.textContent);
      });
    },
    { threshold: 0.42 }
  );

  scrambleTargets.forEach(target => observer.observe(target));
};

const setupWorkflowVideos = () => {
  if (!workflowVideos.length) return;

  if (reducedMotion.matches) {
    workflowVideos.forEach(video => {
      video.removeAttribute('autoplay');
      video.pause();
    });
    return;
  }

  const playVideo = video => {
    const play = video.play();
    if (play) play.catch(() => {});
  };

  const observer = new IntersectionObserver(
    entries => {
      entries.forEach(entry => {
        const video = entry.target;

        if (entry.isIntersecting) {
          playVideo(video);
          return;
        }

        video.pause();
      });
    },
    { rootMargin: '160px 0px', threshold: 0.2 }
  );

  workflowVideos.forEach(video => observer.observe(video));
};

const setupFAQAccordion = () => {
  if (!faqTriggers.length) return;

  const setItemState = (trigger, expanded) => {
    const item = trigger.closest('[data-faq-item]');
    const answerId = trigger.getAttribute('aria-controls');
    const answer = answerId ? document.getElementById(answerId) : null;

    trigger.setAttribute('aria-expanded', String(expanded));
    answer?.setAttribute('aria-hidden', String(!expanded));
    item?.classList.toggle('is-open', expanded);
  };

  faqTriggers.forEach(trigger => {
    trigger.addEventListener('click', () => {
      const shouldOpen = trigger.getAttribute('aria-expanded') !== 'true';

      faqTriggers.forEach(otherTrigger => {
        setItemState(otherTrigger, otherTrigger === trigger && shouldOpen);
      });
    });
  });
};

copyButton?.addEventListener('click', async () => {
  const targetId = copyButton.getAttribute('data-copy-target');
  const target = targetId ? document.getElementById(targetId) : null;
  const text = (target?.dataset.copyText || target?.innerText || '').trim();

  if (!text) return;

  try {
    await navigator.clipboard.writeText(text);
    copyButton.textContent = 'Copied';
    window.setTimeout(() => {
      copyButton.textContent = 'Copy';
    }, 1400);
  } catch {
    copyButton.textContent = 'Select text';
  }
});

setHeaderState();
setupScrambleIn();
setupWorkflowVideos();
setupFAQAccordion();
window.addEventListener('scroll', setHeaderState, { passive: true });
